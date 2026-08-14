#devtools::install_version("duckdb", "1.2.2")
remotes::install_github('cboettig/duckdbfs', upgrade = 'never')
remotes::install_github('eco4cast/score4cast')

library(dplyr)
library(duckdbfs)
library(progress)
library(yaml)
library(stringr)
library(minioclient)
library(DBI)
library(score4cast)
install_mc()

lake_directory <- file.path(here::here())

readr::read_csv("https://raw.githubusercontent.com/computational-limnology/ORM-buoy/refs/heads/main/output/orm_long_processed.csv") |>
  mutate(datetime = as_datetime(datetime)) |>
  readr::write_csv(file.path(lake_directory, "targets", "ORMS", 'ORMS-targets-insitu.csv'))


con <- duckdbfs::cached_connection(tempfile())

rescore <- FALSE
obs_key_cols <- c("project_id", "site_id", "datetime", "duration", "variable", "depth")
score_key_cols <- c(obs_key_cols, "model_id", "family", "reference_datetime")

### Access the targets, forecasts, and scores subsets
targets <-
  duckdbfs::open_dataset(file.path(lake_directory,'targets/ORMS/ORMS-targets-insitu.csv'),
               recursive = FALSE,
               format = "csv",
               parser_options = list(nullstr = "NA"),
               anonymous = TRUE,
  ) |>
  filter(!is.na(observation))


# No point in trying to score any forecasts still in future (relative to last observed)
# (pull forces eval, can take a minute)
last_observed_date <- targets |> select(datetime) |> distinct() |>
  filter(datetime == max(datetime)) |> pull(datetime)

forecasts <-
  duckdbfs::open_dataset(paste0("s3://", "bio230121-bucket01/flare/forecasts/parquet/site_id=ORMS"),
               s3_endpoint = "amnh1.osn.mghpcc.org",
               anonymous=TRUE) |>
  filter(datetime <= {last_observed_date},
         !is.na(model_id),
         !is.na(parameter),
         !is.na(prediction)) |>
  # if necessary, enforce naming convention on "family" to avoid perpetual rescoring
  mutate(family = ifelse(family == 'ensemble', "sample", family),
         duration = "P1D",
         site_id = "ORMS") |>
  # enforce horizon filter
  mutate(horizon = date_diff('day', as.POSIXct(reference_datetime), as.POSIXct(datetime)))

scores <- tryCatch(
  duckdbfs::open_dataset(paste0("s3://", "bio230121-bucket01/flare/scores_v2"),
               s3_endpoint = "amnh1.osn.mghpcc.org", anonymous=TRUE) |>
    filter(!is.na(observation)),
  error = function(e) {
    message("No existing scores found, starting fresh")
    NULL
  }
)


tol <- 1e-2
if(rescore) {
  print("rescoring changed observations")
  # drop rows from scores if the scores and targets disagree on "observation"
  scores <- scores |>
    inner_join(targets, by = obs_key_cols) |>
    filter( abs(observation.x - observation.y)/observation.x < {tol})

  ## Note: Only used to anti-join (filter).
  ## The new observations will come from latest targets

  ## union() won't overwrite those rows.

}



## INSTEAD, we pull our subset to local disk first.
## This looks silly but is much better for RAM and speed!!

  dir.create("temp_scores", recursive = T)
  forecasts |>
    mutate(depth = ifelse(is.na(depth), -9999, depth)) |>
    group_by(site_id) |>
    duckdbfs::write_dataset("temp_scores/forecasts")

  if(!is.null(scores)){
  scores  |>
      mutate(depth = ifelse(is.na(depth), -9999, depth)) |>
      group_by(site_id) |>
      duckdbfs::write_dataset("temp_scores/scores")
  }

  targets |>
    mutate(depth = ifelse(variable != "tempereature", -9999, depth)) |>
    group_by(site_id) |>
    duckdbfs::write_dataset("temp_scores/targets")

  forecasts <- duckdbfs::open_dataset("temp_scores/forecasts/**")
  if(!is.null(scores)){
  scores <- duckdbfs::open_dataset("temp_scores/scores/**")
  }
  targets <- duckdbfs::open_dataset("temp_scores/targets/**")

## Magic rock&roll time: Subset unscored + targets available:
print("Compute who needs to be scored...")
if(is.null(scores)){
  forecasts |>
    inner_join(targets) |> # forecast has targets available
    group_by(site_id) |>
    duckdbfs::write_dataset("temp_scores/score_me")
}else{
  forecasts |>
    anti_join(select(scores, all_of(score_key_cols))) |> # forecast is unscored
    inner_join(targets) |> # forecast has targets available
    group_by(site_id) |>
    duckdbfs::write_dataset("temp_scores/score_me")
}

duckdbfs::close_connection(con)
gc()

score_group <- function(i, groups) {


  # if we want to clear connection manually we need to re-open fc.  Maybe not necessary
  source("workflows/glm_flare_v4/score_joined_table.R")
  con <- duckdbfs::cached_connection(tempfile())
  fc <- duckdbfs::open_dataset("temp_scores/score_me")
  new_scores <- fc |>
    dplyr::inner_join(groups[i,], copy=TRUE,
                      by = dplyr::join_by(site_id, variable, model_id, family)
    ) |>
    dplyr::collect() |>
    score_joined_table()

  ## Append to existing scores
  site_id <- groups$site_id[i]
  var <- groups$variable[i]
  model <- groups$model_id[i]
  path <- glue::glue("s3://",
                     "bio230121-bucket01/flare/scores_v2",
                     "site_id={site_id}/",
                     "variable={var}/model_id={model}")

  path2 <- glue::glue("osn/", "bio230121-bucket01/flare/scores_v2",
                      "site_id={site_id}/",
                      "variable={var}/model_id={model}")


  log <- glue::glue("Joining to existing scores of variable {var} for model {model}")
  message(log)
  #readr::write_lines(log, "new-scoring.log", append=TRUE)

  file_exist <- length(mc_ls(path2))

  duckdbfs::duckdb_secrets(endpoint = "amnh1.osn.mghpcc.org",
                           key = Sys.getenv("AWS_ACCESS_KEY_ID"),
                           secret = Sys.getenv("AWS_SECRET_ACCESS_KEY"),
                           bucket = "bio230121-bucket01/scores_v2")

  if(file_exist > 0){

    new_scores <- duckdbfs::as_dataset(new_scores) |>
      mutate(depth = ifelse(depth == -9999, NA, depth))
    bundled_scores <- duckdbfs::open_dataset(path, conn = con) |>
      dplyr::anti_join(new_scores,
                       by = dplyr::join_by(reference_datetime, site_id, datetime,
                                           family, pub_datetime, observation, depth,
                                           crps, logs, mean, median, sd,
                                           quantile97.5, quantile02.5, quantile90, quantile10,
                                           duration, model_id, project_id, variable)) |>
      dplyr::compute()
    new_scores <- dplyr::union_all(bundled_scores, new_scores)
  }

  new_scores |>
    dplyr::distinct() |>
    dplyr::group_by(site_id, variable, model_id) |>
    duckdbfs::write_dataset(paste0("s3://", "bio230121-bucket01/scores_v2"))

  duckdbfs::close_connection(con)
  gc()
}

fc <- duckdbfs::open_dataset("temp_scores/score_me") |>
  filter(!is.na(model_id))
groups <- fc |> distinct(site_id, variable, model_id, family) |> collect()
total <- nrow(groups)

print("Computing new scores....")
pb <- progress_bar$new(format = "  scoring [:bar] :percent in :elapsed",
                       total = total, clear = FALSE, width= 60)

# If we have lots to score this can take a while
for (i in seq_along(row_number(groups))) {
  pb$tick()
  print(paste("Scoring model:", groups$model_id[i], "variable:", groups$variable[i]))
  score_group(i, groups)

}


