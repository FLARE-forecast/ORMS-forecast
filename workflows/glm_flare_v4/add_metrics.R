s3 <- arrow::s3_bucket(paste0(config$s3$forecasts_parquet$bucket, "/site_id=", config$location$site_id), endpoint_override = config$s3$forecasts_parquet$endpoint, anonymous = TRUE)

ref_date <- as.character(lubridate::as_date(config$run_config$forecast_start_datetime))
forecast_df <- arrow::open_dataset(s3) |>
  filter(model_id == config$run_config$sim_name,
         reference_date == ref_date) |>
  collect() |>
  mutate(datetime = lubridate::as_datetime(datetime))

# Calculate probability of being mixed
min_depth <- 0.5
max_depth <- 5.0
threshold <- 0.1

temp_forecast <- forecast_df |>
  filter(variable == "temperature",
         depth %in% c(min_depth, max_depth)) |>
  mutate(depth_type = ifelse(depth == min_depth, "min_depth", "max_depth"),
         site_id = config$location$site_id) |>
  select(-depth) |>
  pivot_wider(names_from = depth_type, values_from = prediction)

mix_binary_df <- temp_forecast |>
  mutate(min_depth = rLakeAnalyzer::water.density(min_depth),
         max_depth = rLakeAnalyzer::water.density(max_depth),
         mixed = ifelse((max_depth - min_depth) < threshold, 1, 0)) |>
  summarise(prediction = (sum(mixed)/n()), .by = c(datetime, reference_datetime, model_id, site_id, variable, pub_datetime)) |> #pubDate
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

combined_df <- bind_rows(forecast_df, mix_binary_df) |>
  mutate(site_id = config$location$site_id)

s3 <- arrow::s3_bucket(paste0(config$s3$forecasts_parquet$bucket), endpoint_override = config$s3$forecasts_parquet$endpoint)


arrow::write_dataset(dataset = combined_df,
                     path = s3,
                     partitioning = c("site_id", "model_id","reference_date"))

