library(tidyverse)
library(FLAREr)

lake_directory <- file.path(here::here())
setwd(lake_directory)

Sys.setenv('GLM_PATH'= GLMAEDr::glm_path())
Sys.setenv("AWS_DEFAULT_REGION" = "amnh1",
           "AWS_S3_ENDPOINT" = "osn.mghpcc.org",
           "USE_HTTPS" = TRUE)

forecast_site <- "ORMS"
configure_run_file <- "configure_run.yml"
config_set_name <- "glm_flare_v4"

#source('./R/generate_forecast_score_arrow.R')

#' Source the R files in the repository
#walk(list.files(file.path(lake_directory, "R"), full.names = TRUE), source)

configure_run_file <- "configure_run.yml"
config <- FLAREr:::set_up_simulation(configure_run_file,lake_directory, config_set_name = config_set_name, clean_start = FALSE)

# Run FLARE
output <- FLAREr::run_flare(lake_directory = lake_directory,
                            configure_run_file = configure_run_file,
                            config_set_name = config_set_name,
                            clean_start = FALSE)

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
