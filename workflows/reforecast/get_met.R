################################################################################
# Code started by Molly Stroud on 12/16/25
# Download data from dynamical.org and put into correct formatting for FLARE
# https://dynamical.org/catalog/noaa-gefs-forecast-35-day/
#
# This used to drive Python via reticulate, which broke on other machines due
# to reticulate/virtualenv version and configuration mismatches. All of the
# xarray/zarr/pandas logic now lives in R/get_met.py (pure Python, no
# reticulate). This file just provides helpers to set up a dedicated Python
# virtual environment and run get_met.py as a subprocess; 02Get_Inputs.R calls
# .run_get_met_py() directly for stage 2 / stage 3 downloads.
################################################################################

.get_project_root <- function() {
  root <- tryCatch(here::here(), error = function(e) NA_character_)
  if (!is.na(root) && nzchar(root) && dir.exists(root)) {
    return(normalizePath(root, winslash = "/", mustWork = FALSE))
  }
  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
}

.get_met_py_script <- file.path(.get_project_root(), "workflows/reforecast", "get_met.py")
.get_met_venv <- file.path(.get_project_root(), ".venv-met")

.normalize_stage3_met <- function(site_id, bbox, base_dir = file.path("drivers", "met", "gefs-v12", "stage3")) {
  met_dir <- file.path(base_dir, paste0("site_id=", site_id))
  met_file <- file.path(met_dir, "part-0.parquet")

  if (!file.exists(met_file)) {
    return(invisible(FALSE))
  }

  met_df <- arrow::read_parquet(met_file)
  met_df$datetime <- lubridate::as_datetime(met_df$datetime, tz = "UTC")

  if (!"site_id" %in% names(met_df)) {
    met_df$site_id <- site_id
  }

  unique_time <- sort(unique(met_df$datetime))
  needs_hourly <- length(unique_time) >= 2 &&
    as.numeric(difftime(unique_time[2], unique_time[1], units = "hours")) > 1

  flux_vars <- c("precipitation_flux", "surface_downwelling_shortwave_flux_in_air", "surface_downwelling_longwave_flux_in_air")
  flux_summary <- met_df |>
    dplyr::filter(variable %in% flux_vars) |>
    dplyr::group_by(variable) |>
    dplyr::summarise(non_na = sum(!is.na(prediction)), .groups = "drop")
  missing_flux_var <- any(!flux_vars %in% flux_summary$variable)
  empty_flux_var <- any(flux_summary$non_na == 0)
  needs_flux_repair <- missing_flux_var || empty_flux_var

  if (!needs_hourly && !needs_flux_repair) {
    return(invisible(FALSE))
  }

  source(file.path("R", "to_hourly.R"), local = TRUE)

  if (needs_hourly) {
    mean_lon <- mean(c(as.numeric(bbox[["left"]]), as.numeric(bbox[["right"]])))
    mean_lat <- mean(c(as.numeric(bbox[["bottom"]]), as.numeric(bbox[["top"]])))
    met_df <- get_hourly(met_df,
                         mean_lon = mean_lon,
                         mean_lat = mean_lat)
    met_df$datetime <- lubridate::as_datetime(met_df$datetime, tz = "UTC")
  }

  if (needs_flux_repair) {
    if (!"site_id" %in% names(met_df)) {
      met_df$site_id <- site_id
    }

    air_temp_lookup <- met_df |>
      dplyr::filter(variable == "air_temperature") |>
      dplyr::select(parameter, datetime, air_temp_k = prediction)

    mean_lon <- mean(c(as.numeric(bbox[["left"]]), as.numeric(bbox[["right"]])))
    mean_lat <- mean(c(as.numeric(bbox[["bottom"]]), as.numeric(bbox[["top"]])))
    solar_lon <- ifelse(mean_lon < 0, 360 + mean_lon, mean_lon)

    met_df <- met_df |>
      dplyr::left_join(air_temp_lookup, by = c("parameter", "datetime")) |>
      dplyr::mutate(
        prediction = dplyr::case_when(
          variable == "precipitation_flux" & is.na(prediction) ~ 0,
          variable == "surface_downwelling_shortwave_flux_in_air" & is.na(prediction) ~
            downscale_solar_geom(
              lubridate::yday(datetime) + lubridate::hour(datetime) / 24,
              solar_lon,
              mean_lat
            ) * 0.5,
          variable == "surface_downwelling_longwave_flux_in_air" & is.na(prediction) ~
            0.97 * 5.67e-8 * (air_temp_k^4),
          TRUE ~ prediction
        )
      ) |>
      dplyr::select(-air_temp_k) |>
      dplyr::group_by(site_id, family, parameter, variable) |>
      dplyr::arrange(datetime, .by_group = TRUE) |>
      tidyr::fill(prediction, .direction = "downup") |>
      dplyr::ungroup()
  }

  met_df |>
    dplyr::select(-site_id) |>
    arrow::write_parquet(met_file)

  message(paste0("Normalized stage3 met data for site ", site_id,
                 " (hourly: ", needs_hourly,
                 ", flux_repair: ", needs_flux_repair, ")."))
  invisible(TRUE)
}

# path to the python executable inside the dedicated virtual environment
.get_met_venv_python <- function() {
  if (.Platform$OS.type == "windows") {
    file.path(.get_met_venv, "Scripts", "python.exe")
  } else {
    file.path(.get_met_venv, "bin", "python3")
  }
}

# make sure a python3 interpreter + dedicated venv with the right packages exist
.find_system_python <- function() {
  if (.Platform$OS.type == "windows") {
    py_launcher <- Sys.which("py")
    if (nzchar(py_launcher)) {
      return(list(cmd = py_launcher, args = c("-3"), label = "py -3"))
    }
  }

  python3 <- Sys.which("python3")
  if (nzchar(python3)) {
    return(list(cmd = python3, args = character(0), label = "python3"))
  }

  python <- Sys.which("python")
  if (nzchar(python)) {
    return(list(cmd = python, args = character(0), label = "python"))
  }

  stop(
    "Could not find a Python 3 interpreter on PATH. Tried py -3 (Windows), ",
    "python3, and python. Please install Python 3 and try again."
  )
}

.ensure_met_python_env <- function() {
  system_python <- .find_system_python()

  venv_python <- .get_met_venv_python()

  if (!file.exists(.get_met_py_script)) {
    stop("Could not find get_met.py at: ", .get_met_py_script)
  }

  if (!file.exists(venv_python)) {
    message("Creating a dedicated Python environment for met data downloads (.venv-met)...")
    result <- system2(system_python$cmd, c(system_python$args, "-m", "venv", .get_met_venv))
    if (result != 0) {
      stop(
        "Failed to create the Python virtual environment used by get_met.py ",
        "with interpreter: ", system_python$label
      )
    }
  }

  # bump this when `packages` below changes so existing .venv-met installs
  # (which skip installation once the marker file exists) get upgraded
  required_marker <- "packages-v2"

  marker <- file.path(.get_met_venv, "packages_installed.txt")
  installed_marker <- if (file.exists(marker)) readLines(marker, warn = FALSE)[1] else NA_character_

  if (!identical(installed_marker, required_marker)) {
    message("Installing required Python packages for met data downloads...")
    packages <- c(
      "dask==2025.1.0",
      "xarray[complete]==2026.1.0",
      "zarr>=3.2,<4",
      "certifi",
      "numpy",
      "pandas",
      "pyarrow",
      "requests",
      "aiohttp",
      "dynamical-catalog"
    )
    # shQuote() protects package specifiers with shell-special characters
    # (e.g. "zarr>=3.2,<4") from being interpreted by the shell that
    # system2() invokes them through
    system2(venv_python, c("-m", "pip", "install", "--quiet", "--upgrade", "pip"))
    result <- system2(venv_python, c("-m", "pip", "install", "--quiet", shQuote(packages)))
    if (result != 0) {
      stop("Failed to install the Python packages required by get_met.py.")
    }
    writeLines(required_marker, marker)
  }

  venv_python
}

# Run get_met.py for a single reference_datetime.
#
# For "stage2", one forecast cycle (the full ~35-day horizon) for that
# reference_datetime is downloaded. The Python CLI uses --start-date==--end-date
# (both set to reference_datetime) so every forecast horizon is retained. For
# "stage3", reference_datetime is the start date and end_date is its optional
# end date; stage3 pulls from the NOAA GEFS *analysis* dataset (a single
# deterministic time series, not per-day forecast cycles), so the whole
# start_date..end_date window is fetched in one request.
#
# "stage3_update" also pulls from the analysis dataset over
# reference_datetime..end_date, but first compares that window against the
# datetimes already present in the existing stage3 parquet for site_id and
# only downloads the datetimes that are missing. The newly downloaded rows
# are merged into the existing parquet (new values win on overlap) and the
# combined result is rewritten sorted by datetime ascending. Use this instead
# of "stage3" to extend an existing archive without re-downloading data that
# is already on disk.
.run_get_met_py <- function(stage, site_id, bbox, reference_datetime, end_date = NULL) {
  stage <- match.arg(stage, c("stage2", "stage3", "stage3_update"))

  if (identical(stage, "stage2")) {
    end_date <- reference_datetime
    if (is.null(end_date)) {
      stop("reference_datetime is required for stage2.")
    }
  }

  args <- c(
    stage,
    "--site", site_id,
    "--bbox", bbox[["left"]], bbox[["bottom"]], bbox[["right"]], bbox[["top"]],
    "--start-date", as.character(reference_datetime),
    "--end-date", as.character(end_date)
  )

  venv_python <- .ensure_met_python_env()
  result <- system2(venv_python, c(.get_met_py_script, as.character(args)))
  if (result != 0) {
    stop("get_met.py failed. See the messages above for details.")
  }

  if (stage %in% c("stage3", "stage3_update")) {
    .normalize_stage3_met(site_id = site_id, bbox = bbox)
  }

  invisible(result)
}

