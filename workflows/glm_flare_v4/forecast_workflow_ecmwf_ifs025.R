library(tidyverse)
library(FLAREr)

lake_directory <- file.path(here::here())
setwd(lake_directory)

Sys.setenv('GLM_PATH'= GLMAEDr::glm_path())
Sys.setenv("AWS_DEFAULT_REGION" = "amnh1",
           "AWS_S3_ENDPOINT" = "osn.mghpcc.org",
           "USE_HTTPS" = TRUE,
           "AWS_REQUEST_CHECKSUM_CALCULATION"= "when_required",
           "AWS_RESPONSE_CHECKSUM_VALIDATION"= "when_required")

forecast_site <- "ORMS"
configure_run_file <- "configure_run_ecmwf_ifs025.yml"
config_set_name <- "glm_flare_v4"
reset_run <- FALSE


source(file.path(lake_directory, "workflows", config_set_name, "add_metrics.R"))
source(file.path(lake_directory, "workflows", config_set_name, "extract_met_forecast.R"))

config <- FLAREr:::set_up_simulation(configure_run_file,lake_directory, config_set_name = config_set_name, clean_start = reset_run)

read_csv("https://raw.githubusercontent.com/computational-limnology/ORM-buoy/refs/heads/main/output/orm_long_processed.csv") |>
  mutate(datetime = as_datetime(datetime)) |>
  write_csv(file.path(lake_directory, "targets", config$location$site_id, config$da_setup$obs_filename))

#FLAREr::flare_get_file(local_file = config$da_setup$obs_filename,
#               remote_file = config$da_setup$obs_filename,
#               server_name = "targets",
#               local_folder = file.path(lake_directory, "targets", config$location$site_id),
#               remote_folder = file.path("flare", "targets", config$location$site_id),
#               config)

# Run FLARE
FLAREr::run_flare(lake_directory = lake_directory,
                            configure_run_file = configure_run_file,
                            config_set_name = config_set_name,
                            clean_start = reset_run)

# Add additional mixing variables here
add_metrics(use_s3 = config$run_config$use_s3,
            site_id = config$location$site_id,
            forecast_start_datetime = config$run_config$forecast_start_datetime,
            sim_name = config$run_config$sim_name,
            bucket = config$s3$forecasts_parquet$bucket,
            endpoint = config$s3$forecasts_parquet$endpoint,
            local_dir = file.path(lake_directory, "forecasts", "parquet"),
            nml_file = file.path(lake_directory, "configuration", config_set_name, "glm3.nml"))

# Extract met ensemble forecast (air temperature, wind speed) and write to the forecast bucket
extract_met_forecast(met_dir = config$file_path$execute_directory,
                     met_model_id = config$met$openmeteo_model,
                     site_id = config$location$site_id,
                     forecast_start_datetime = config$run_config$forecast_start_datetime,
                     use_s3 = config$run_config$use_s3,
                     bucket = config$s3$forecasts_parquet$bucket,
                     endpoint = config$s3$forecasts_parquet$endpoint,
                     local_dir = file.path(lake_directory, "forecasts", "parquet"))

forecast_start_datetime <- lubridate::as_datetime(config$run_config$forecast_start_datetime) + lubridate::days(1)
start_datetime <- forecast_start_datetime - lubridate::days(3)
restart_file <- paste0(config$location$site_id,"-",
                       lubridate::as_datetime(config$run_config$forecast_start_datetime),
                       "-",
                       config$run_config$sim_name ,".zip")

FLAREr:::update_run_config(lake_directory = lake_directory,
                           configure_run_file = configure_run_file,
                           restart_file = restart_file,
                           start_datetime = start_datetime,
                           end_datetime = NA,
                           forecast_start_datetime = forecast_start_datetime,
                           forecast_horizon = config$run_config$forecast_horizon,
                           sim_name = config$run_config$sim_name,
                           site_id = config$location$site_id,
                           configure_flare = config$run_config$configure_flare,
                           configure_obs = config$run_config$configure_obs,
                           use_s3 = config$run_config$use_s3,
                           bucket = config$s3$restart$bucket,
                           endpoint = config$s3$restart$endpoint,
                           config = config,
                           use_https = TRUE)
