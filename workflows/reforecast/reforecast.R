library(tidyverse)
library(lubridate)
library(minioclient)
set.seed(200)

Sys.setenv('GLM_PATH'= GLMAEDr::glm_path())
Sys.setenv("AWS_DEFAULT_REGION" = "amnh1",
           "AWS_S3_ENDPOINT" = "osn.mghpcc.org",
           "USE_HTTPS" = TRUE,
           "AWS_REQUEST_CHECKSUM_CALCULATION"= "when_required",
           "AWS_RESPONSE_CHECKSUM_VALIDATION"= "when_required")
# This need to be set to run each experiment

run_name <- "reforecast_v1"
config_flare_file <- "configure_flare_glm.yml"
starting_index <- 1 #260
source(file.path(lake_directory, "workflows", "glm_flare_v4", "add_metrics.R"))
source(file.path(lake_directory, "workflows", "reforecast", "generate_forecast_score_arrow.R"))

# These don't need to be changed

config_set_name <- "glm_flare_v4"
site <- "ORMS"
configure_run_file <- "configure_run.yml"
use_s3 <- TRUE
experiments <- "ncep"
lake_directory <- here::here()

options(future.globals.maxSize = 891289600)

### Set up simulation start and end dates

num_forecasts <- 275
days_between_forecasts <- 7
forecast_horizon <- 14
starting_date <- as_date("2024-12-27")
starting_date <- as_date("2020-12-15")
second_date <- as_date("2021-01-01") - days(days_between_forecasts)

all_dates <- seq.Date(starting_date,second_date + days(days_between_forecasts * num_forecasts), by = days_between_forecasts)

potential_date_list <- list(ncep = all_dates)

date_list <- potential_date_list[which(names(potential_date_list) %in% experiments)]

models <- names(date_list)

start_dates <- as_date(rep(NA, num_forecasts + 1))
end_dates <- as_date(rep(NA, num_forecasts + 1))
start_dates[1] <- starting_date
end_dates[1] <- second_date
for(i in 2:(num_forecasts+1)){
  start_dates[i] <- as_date(end_dates[i-1])
  end_dates[i] <- start_dates[i] + days(days_between_forecasts)
}

sims <- expand.grid(paste0(start_dates,"_",end_dates,"_", forecast_horizon), models)

names(sims) <- c("date","model")

sims$start_dates <- stringr::str_split_fixed(sims$date, "_", 3)[,1]
sims$end_dates <- stringr::str_split_fixed(sims$date, "_", 3)[,2]
sims$horizon <- stringr::str_split_fixed(sims$date, "_", 3)[,3]

sims <- sims |>
  mutate(model = as.character(model)) |>
  select(-date) |>
  distinct_all() |>
  arrange(start_dates)

sims$horizon[1:length(models)] <- 0

for(i in starting_index:nrow(sims)){

  message(paste0("index: ", i))
  message(paste0("     Running model: ", sims$model[i], " "))

  model <- sims$model[i]
  sim_names <- run_name

  config <- FLAREr::set_up_simulation(configure_run_file, lake_directory, config_set_name = config_set_name, sim_name = sim_names, clean_start = TRUE)

  yml <- yaml::read_yaml(file.path(lake_directory, "configuration", config_set_name, configure_run_file))
  yml$sim_name <- sim_names
  yml$configure_flare <- config_flare_file
  yaml::write_yaml(yml, file.path(lake_directory, "configuration", config_set_name, configure_run_file))

  run_config <- yaml::read_yaml(file.path(lake_directory, "configuration", config_set_name, configure_run_file))
  run_config$configure_flare <- config_flare_file
  run_config$sim_name <- sim_names
  run_config$start_datetime <- as.character(paste0(sims$start_dates[i], " 00:00:00"))
  run_config$forecast_start_datetime <- as.character(paste0(sims$end_dates[i], " 00:00:00"))
  run_config$forecast_horizon <- as.numeric(sims$horizon[i])
  run_config$configure_flare <- config_flare_file
  run_config$use_s3 <- use_s3
  if(i <= length(models)){
    config$run_config$restart_zip_file <- NA
  }else{
    run_config$restart_file <- paste0(config$location$site_id, "-", lubridate::as_date(run_config$start_datetime), "-", sim_names, ".zip")
  }

  yaml::write_yaml(run_config, file = file.path(lake_directory, "restart", site, sim_names, configure_run_file))

  configure_run_file <- "configure_run.yml"
  config <- FLAREr:::set_up_simulation(configure_run_file,lake_directory, config_set_name = config_set_name, clean_start = reset_run)

  if(i == 1){
  FLAREr::flare_get_file(local_file = config$da_setup$obs_filename,
                         remote_file = config$da_setup$obs_filename,
                         server_name = "targets",
                         local_folder = file.path(lake_directory, "targets", config$location$site_id),
                         remote_folder = file.path("flare", "targets", config$location$site_id),
                         config)
  }

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

  targets_df <- read_csv(file.path(lake_directory, "targets", config$location$site_id, config$da_setup$obs_filename))

  s3 <- arrow::s3_bucket(paste0(config$s3$forecasts_parquet$bucket, "/site_id=", config$location$site_id),
                           endpoint_override = config$s3$forecasts_parquet$endpoint,
                           anonymous = TRUE)

  ref_date <- as.character(lubridate::as_date(config$run_config$forecast_start_datetime))
  forecast_df <- arrow::open_dataset(s3) |>
    filter(model_id == config$run_config$sim_name,
           reference_date == ref_date) |>
    collect() |>
    mutate(datetime = lubridate::as_datetime(datetime))

  generate_forecast_score_arrow(targets_df = targets_df,
                                forecast_df = forecast_df,
                                use_s3 = TRUE,
                                bucket = config$s3$scores$bucket,
                                endpoint = config$s3$scores$endpoint,
                                local_directory = file.path(lake_directory, "scores/parquet"),
                                variable_types = c("state","parameter","diagnostic"))
}

