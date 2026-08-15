#' Extract air temperature and wind speed from the ensemble meteorology
#' files FLARE generated for the run, and write them out in the same
#' format as the FLARE forecast data frame.
#' @param met_dir directory containing the per-ensemble met_*.csv files
#'   (config$file_path$execute_directory)
#' @param met_model_id the meteorology model used to drive the run
#'   (config$met$openmeteo_model); used as the forecast's model_id
#' @param site_id site code
#' @param forecast_start_datetime reference_datetime of the forecast
#' @param use_s3,bucket,endpoint,local_dir where to write the resulting
#'   forecast parquet dataset (same convention as add_metrics())
extract_met_forecast <- function(met_dir, met_model_id, site_id, forecast_start_datetime,
                                 use_s3, bucket, endpoint, local_dir){

  reference_datetime <- lubridate::as_datetime(forecast_start_datetime)
  pub_datetime <- lubridate::with_tz(Sys.time(), tzone = "UTC")

  met_files <- list.files(met_dir,
                          pattern = paste0("^met_", met_model_id, "_.*\\.csv$"),
                          full.names = TRUE)

  if(length(met_files) == 0){
    warning(paste0("No meteorology ensemble files found for model '", met_model_id, "' in ", met_dir))
    return(invisible(NULL))
  }

  # loop over the ensemble members, pulling AirTemp and WindSpeed out of
  # each GLM-formatted met file
  met_forecast <- purrr::map_dfr(met_files, function(f){
    ensemble <- basename(f) |>
      stringr::str_remove(paste0("^met_", met_model_id, "_")) |>
      stringr::str_remove("\\.csv$")

    readr::read_csv(f, show_col_types = FALSE) |>
      dplyr::transmute(datetime = time,
                       air_temperature = AirTemp,
                       wind_speed = WindSpeed) |>
      tidyr::pivot_longer(cols = c(air_temperature, wind_speed),
                          names_to = "variable", values_to = "prediction") |>
      dplyr::filter(!is.na(prediction)) |>
      dplyr::mutate(parameter = ensemble)
  })

  met_forecast <- met_forecast |>
    dplyr::mutate(reference_datetime = reference_datetime,
                  pub_datetime = pub_datetime,
                  depth = NA_real_,
                  family = "ensemble",
                  variable_type = "driver",
                  model_id = met_model_id,
                  reference_date = as.character(lubridate::as_date(reference_datetime)),
                  site_id = site_id) |>
    dplyr::select(reference_datetime, datetime, pub_datetime, depth, family, parameter,
                  variable, prediction, variable_type, model_id,
                  reference_date, site_id) |>
    # ensemble members can show up more than once across files, so drop exact duplicates
    dplyr::distinct()

  if(use_s3){
    s3 <- arrow::s3_bucket(bucket, endpoint_override = endpoint)
  }else{
    s3 <- local_dir
  }

  arrow::write_dataset(dataset = met_forecast,
                       path = s3,
                       partitioning = c("site_id", "model_id", "reference_date"))

  met_forecast
}
