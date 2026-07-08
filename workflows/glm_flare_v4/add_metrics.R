core_metrics <- function(in_temp, in_depth_temp, dz = 0.1,
                         g = 9.81){



  # hard coded morphometry for Ormstrup!!!!
  in_depth_area <- c(
    0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
    1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9,
    2, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9,
    3, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9,
    4, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9,
    5, 5.1, 5.2, 5.3, 5.4, 5.5
  )

  in_area <- c(
    109249, 109249, 109249, 109051.3, 108655.9, 108260.5,
    107865.1, 107469.7, 106981.1, 106399.3, 105817.5,
    105235.7, 104653.9, 103998.2, 103268.6, 102539,
    101809.4, 101079.8, 100150.2, 99020.6, 97891,
    96761.4, 95631.8, 93880.3, 91506.9, 89133.5,
    86760.1, 84386.7, 81639.2, 78517.6, 75396,
    72274.4, 69152.8, 66155.8, 63283.4, 60411,
    57538.6, 54666.2, 50848.8, 46086.4, 41324,
    36561.6, 31799.2, 27453.9, 23525.7, 19597.5,
    15669.3, 11741.1, 9060.4, 7627.2, 6194,
    4760.8, 3327.6, 2611, 2611, 2611
  )

  max_depth <- max(in_depth_area, in_depth_temp, na.rm = T)

  depth <- seq(0, max_depth, by = dz)

  area <- approx(x = in_depth_area, y = in_area, xout = depth, method = 'linear', rule = 2)$y

  temp <- approx(x = in_depth_temp, y = in_temp, xout = depth, method = 'linear', rule = 2)$y

  temp <- zoo::na.approx(temp)
  # ---- Center of Volume ----
  # z_v = (∫ z A dz) / (∫ A dz)
  V = trapz(area, depth) * (-1)
  z_v = (-1) * trapz(depth * area, depth) / V

  rho = water.density(temp)

  # ---- Center of Gravity ----
  # z_g(t) = (∫ z rho A dz) / (∫ rho A dz)
  mass = trapz(rho * area, depth) * (-1)
  z_g = (-1) * trapz(depth * rho * area, depth) / mass

  # ---- Mean density ----
  # rho_mean(t) = (∫ rho A dz) / (∫ A dz)
  rho_mean = mass / V

  # ---- Mean depth ----
  # z_mean = (∫ A dz) / A
  z_mean= V/max(area)

  # ---- Schmidt stability ----
  # Ws = gˆzρ(zg − zv )
  Ws = g * z_mean * rho_mean * (z_g - z_v)

  # ---- Metalimnion thickness ----
  meta_depths <- meta.depths(wtr = temp, depths = depth)
  delta_meta_depths = meta_depths[2] - meta_depths[1]


  w <- area * dz
  w <- w / sum(w)


  rho_hat <- sum(w * rho)
  z_v_w     <- sum(w * depth)

  # volume-weighted covariance
  covV <- sum(w * (rho - rho_hat) * (depth - z_v_w))
  covV <- sum(w * (rho - rho_mean) * (depth - z_v))

  # deviations from mean
  rho_p = rho - rho_mean
  z_p = depth - z_v

  # moments
  M1 = sum(w * rho_p * z_p)
  M2 = sum(w * rho_p * z_p^2)

  # variances
  sigma_rho = sqrt(sum(w * rho_p^2))
  sigma_z = sqrt(sum(w * z_p^2))

  # cauchy-schwartz?
  eta <- M1 / (sigma_rho * sigma_z)

  # moment ratio
  m_ratio = M2 / M1

  # print(z_v)
  # print(z_g)
  # print(z_mean)
  # print(rho_mean)
  # print(Ws)

  z_therm <- thermo.depth(wtr = temp, depths = depth)
  z_n2 <- center.buoyancy(wtr = temp, depths = depth)

  n2 <- buoyancy.freq(wtr = temp, depths = depth)
  n2_max = max(n2, na.rm = T)

  b_z <- - 9.81 * (rho - rho_mean)/(rho_mean)
  # ---- Center of Gravity ----
  # z_g(t) = (∫ z rho A dz) / (∫ rho A dz)
  b_var <- sum(w *b_z**2)


  return(data.frame(Ws = Ws,
              M1 = M1, M2 = M2, eta = eta, m_ratio = m_ratio, z_therm = z_therm,
              z_n2 = z_n2, n2_max = n2_max, b_var = b_var))

}

add_metrics <- function(use_s3, site_id, forecast_start_datetime, sim_name, bucket, endpoint, local_dir){

  if(use_s3){
    s3 <- arrow::s3_bucket(paste0(bucket, "/site_id=", site_id),
                           endpoint_override = endpoint,
                           anonymous = TRUE)
  }else{
    s3 <- local_dir
  }

  ref_date <- as.character(lubridate::as_date(forecast_start_datetime))
  forecast_df <- arrow::open_dataset(s3) |>
    filter(model_id == sim_name,
           reference_date == ref_date) |>
    collect() |>
    mutate(datetime = lubridate::as_datetime(datetime))

  # Calculate probability of being mixed
  min_depth <- 0.5
  max_depth <- 5.0
  threshold <- 0.1



  # implementation of physical mixing metrics -------------------------------

  # parameter = ensemble member number
  # datetime =  the datetime that the forecast applies.
  # reference_datetime = start of the 14-day ahead forecast

  physics_forecast <- forecast_df %>% filter(variable == "temperature") %>%
    group_by(datetime, reference_datetime, parameter) %>%
    group_modify(~ {

      core_metrics(
        in_temp = .x$prediction,
        in_depth_temp = .x$depth
      )

    })

  mix_physics_df <- physics_forecast %>%
    pivot_longer(
      cols = Ws:last_col(),
      names_to = "variable",
      values_to = "prediction"
    ) %>%

    left_join(
      forecast_df %>% select(pub_datetime, model_id, datetime, reference_datetime, parameter),
      by = c('datetime', 'reference_datetime', 'parameter')
    ) %>%  distinct() %>%

    dplyr::mutate(family = "bernoulli", #something else
                  parameter = "prob", # something else
                  depth = NA,
                  datetime = lubridate::as_datetime(datetime),
                  variable_type = "diagnostic",
                  reference_date = as.character(as_date(reference_datetime)),
                  log_weight = 0,
                  forecast = NA,) |>
    dplyr::select(names(forecast_df))

  ###

  temp_forecast <- forecast_df |>
    filter(variable == "temperature",
           depth %in% c(min_depth, max_depth)) |>
    mutate(depth_type = ifelse(depth == min_depth, "min_depth", "max_depth"),
           site_id = site_id) |>
    select(-depth) |>
    pivot_wider(names_from = depth_type, values_from = prediction)

  mix_binary_df <- temp_forecast |>
    mutate(min_depth = rLakeAnalyzer::water.density(min_depth),
           max_depth = rLakeAnalyzer::water.density(max_depth),
           mixed = ifelse((max_depth - min_depth) < threshold, 1, 0)) |>
    summarise(prediction = (sum(mixed)/n()), .by = c(datetime, reference_datetime, model_id, site_id, variable, pub_datetime)) |>
    dplyr::mutate(family = "bernoulli",
                  parameter = "prob",
                  variable = "prob_mixed_density",
                  depth = NA,
                  datetime = lubridate::as_datetime(datetime),
                  variable_type = "diagnostic",
                  reference_date = as.character(as_date(reference_datetime)),
                  log_weight = 0,
                  forecast = NA,) |>
    dplyr::select(names(forecast_df))

  forecast_df <- forecast_df |>
    mutate(parameter = as.character(parameter))

  combined_df <- bind_rows(forecast_df, mix_binary_df, mix_physics_df) |>
    mutate(site_id = site_id)


  if(use_s3){
    s3 <-  arrow::s3_bucket(paste0(bucket), endpoint_override = endpoint)
  }else{
    s3 <- local_dir
  }

  arrow::write_dataset(dataset = combined_df,
                       path = s3,
                       partitioning = c("site_id", "model_id","reference_date"))
}

