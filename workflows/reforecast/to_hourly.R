# function: convert dataframe to hourly time steps
pacman::p_load("imputeTS")
get_hourly <- function(df, mean_lon, mean_lat){
  var_order <- names(df)
  parameters <- unique(df$parameter)
  datetime <- seq(min(df$datetime), max(df$datetime), by = "1 hour")
  variables <- unique(df$variable)
  sites <- unique(df$site_id)

  parameter_maxtime <- df |>
    dplyr::group_by(site_id, family, parameter) |>
    dplyr::summarise(max_time = max(datetime), .groups = "drop")

  full_time <- expand.grid(sites, parameters, datetime, variables) |>
    dplyr::rename(site_id = Var1,
                  parameter = Var2,
                  datetime = Var3,
                  variable = Var4) |>
    dplyr::mutate(datetime = lubridate::as_datetime(datetime)) |>
    dplyr::arrange(site_id, parameter, variable, datetime) |>
    dplyr::left_join(parameter_maxtime, by = c("site_id","parameter")) |>
    dplyr::filter(datetime <= max_time) |>
    dplyr::select(-c("max_time")) |>
    dplyr::distinct()

  states <- df |>
    dplyr::select(site_id, family, parameter, datetime, variable, prediction) |>
    dplyr::group_by(site_id, parameter, variable) |>
    dplyr::right_join(full_time, by = c("site_id", "parameter", "datetime", "family", "variable")) |>
    dplyr::filter(variable %in% c("air_pressure", "relative_humidity",
                                  "air_temperature", "eastward_wind", "northward_wind")) |>
    dplyr::arrange(site_id, parameter, datetime) |>
    dplyr::mutate(prediction =  imputeTS::na_interpolation(prediction, option = "linear")) |>
    dplyr::mutate(prediction = ifelse(variable == "RH", prediction/100, prediction)) |>
    dplyr::ungroup()

  fluxes <- df |>
    dplyr::select(site_id, family, parameter, datetime, variable, prediction) |>
    dplyr::group_by(site_id, family, parameter, variable) |>
    dplyr::right_join(full_time, by = c("site_id", "parameter", "datetime", "family", "variable")) |>
    dplyr::filter(variable %in% c("precipitation_flux","surface_downwelling_longwave_flux_in_air","surface_downwelling_shortwave_flux_in_air")) |>
    dplyr::arrange(site_id, family, parameter, datetime) |>
    tidyr::fill(prediction, .direction = "up") |>
    # NOTE: dynamical.org's precipitation_surface is already a rate in
    # kg m-2 s-1 ("average precipitation rate since the previous forecast
    # step"), not a 6-hour accumulated depth, so no unit conversion is
    # needed here. (This used to divide by 6*60*60, carried over from a
    # legacy 6-hourly-accumulated GEFS source; that made the output
    # ~21,600x too small.)
    dplyr::ungroup()

  fluxes <- fluxes |>
    dplyr::mutate(hour = lubridate::hour(datetime),
                  date = lubridate::as_date(datetime),
                  doy = lubridate::yday(datetime) + hour/24,
                  longitude = ifelse(mean_lon < 0, 360 + mean_lon, mean_lon),
                  rpot = downscale_solar_geom(doy, mean_lon, mean_lat)) |>  # hourly sw flux calculated using solar geometry
    dplyr::group_by(site_id, family, parameter, date, variable) |>
    dplyr::mutate(avg.rpot = mean(rpot, na.rm = TRUE),
                  avg.SW = mean(prediction, na.rm = TRUE))|> # daily sw mean from solar geometry
    dplyr::ungroup() |>
    dplyr::mutate(prediction = ifelse(variable == "surface_downwelling_shortwave_flux_in_air" & avg.rpot > 0.0, rpot * (avg.SW/avg.rpot),prediction))# |>
  #dplyr::select(any_of(var_order))

  hourly_df <- dplyr::bind_rows(states, fluxes) |>
    dplyr::arrange(site_id, family, variable, datetime) |>
    dplyr::select(any_of(var_order))
  return(hourly_df)
}


cos_solar_zenith_angle <- function(doy, lat, lon, dt, hr) {
  et <- equation_of_time(doy)
  merid  <- floor(lon / 15) * 15
  merid[merid < 0] <- merid[merid < 0] + 15
  lc     <- (lon - merid) * -4/60  ## longitude correction
  tz     <- merid / 360 * 24  ## time zone
  midbin <- 0.5 * dt / 86400 * 24  ## shift calc to middle of bin
  t0   <- 12 + lc - et - tz - midbin  ## solar time
  h    <- pi/12 * (hr - t0)  ## solar hour
  dec  <- -23.45 * pi / 180 * cos(2 * pi * (doy + 10) / 365)  ## declination
  cosz <- sin(lat * pi / 180) * sin(dec) + cos(lat * pi / 180) * cos(dec) * cos(h)
  cosz[cosz < 0] <- 0
  return(cosz)
}

equation_of_time <- function(doy) {
  stopifnot(doy <= 367)
  f      <- pi / 180 * (279.5 + 0.9856 * doy)
  et     <- (-104.7 * sin(f) + 596.2 * sin(2 * f) + 4.3 *
               sin(4 * f) - 429.3 * cos(f) - 2 *
               cos(2 * f) + 19.3 * cos(3 * f)) / 3600  # equation of time -> eccentricity and obliquity
  return(et)
}

downscale_solar_geom <- function(doy, lon, lat) {

  dt <- median(diff(doy)) * 86400 # average number of seconds in time interval
  hr <- (doy - floor(doy)) * 24 # hour of day for each element of doy

  ## calculate potential radiation
  cosz <- cos_solar_zenith_angle(doy, lat, lon, dt, hr)
  rpot <- 1366 * cosz
  return(rpot)
}
