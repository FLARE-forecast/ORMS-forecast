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

#source('./R/generate_forecast_score_arrow.R')

#' Source the R files in the repository
#walk(list.files(file.path(lake_directory, "R"), full.names = TRUE), source)

config <- FLAREr:::set_up_simulation(configure_run_file,lake_directory, config_set_name = config_set_name, clean_start = reset_run)

FLAREr::flare_get_file(local_file = config$da_setup$obs_filename,
               remote_file = config$da_setup$obs_filename,
               server_name = "targets",
               local_folder = file.path(lake_directory, "targets", config$location$site_id),
               remote_folder = file.path("flare", "targets", config$location$site_id),
               config)

# Run FLARE
FLAREr::run_flare(lake_directory = lake_directory,
                            configure_run_file = configure_run_file,
                            config_set_name = config_set_name,
                            clean_start = reset_run)

# Add additional mixing variables here
add_metrics(bucket = config$s3$forecasts_parquet$bucket,
            endpoint = config$s3$forecasts_parquet$endpoint,
            site_id = config$location$site_id,
            forecast_start_datetime = config$run_config$forecast_start_datetime,
            sim_name = config$run_config$sim_name)

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
