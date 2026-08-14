#remotes::install_github('cboettig/duckdbfs', upgrade = 'never')
#remotes::install_github('eco4cast/score4cast')

library(dplyr)
library(duckdbfs)
library(progress)
library(yaml)
library(stringr)
library(minioclient)
library(DBI)
library(score4cast)
install_mc()

# =============================================================================
# Configuration - edit these values to point this script at a different
# site, deployment, or storage location.
# =============================================================================

SITE_ID <- "ORMS"
LAKE_DIRECTORY <- here::here()

# Source of the raw insitu observation data, and where the processed copy
# is written locally before it is used as the scoring "targets" file.
TARGETS_URL <- "https://raw.githubusercontent.com/computational-limnology/ORM-buoy/refs/heads/main/output/orm_long_processed.csv"
TARGETS_FILE <- file.path(LAKE_DIRECTORY, "targets", SITE_ID, paste0(SITE_ID, "-targets-insitu.csv"))

# S3 (OSN) storage locations for forecasts and scores
S3_ENDPOINT <- "amnh1.osn.mghpcc.org"
S3_BUCKET <- "bio230121-bucket01"
FORECASTS_S3_PATH <- paste0("s3://", S3_BUCKET, "/flare/forecasts/parquet/site_id=", SITE_ID)
SCORES_S3_SUBPATH <- paste0(S3_BUCKET, "/flare/scores_v2")
SCORES_S3_PATH <- paste0("s3://", SCORES_S3_SUBPATH)
SCORES_OSN_PATH <- paste0("osn/", SCORES_S3_SUBPATH)

# Local working directory used to stage data during scoring, and the
# location of the helper script that implements the scoring calculation.
TEMP_DIR <- "temp_scores"
SCORE_FUNCTION_SCRIPT <- "workflows/glm_flare_v4/score_joined_table.R"

# Whether to drop and recompute scores whose target observation has since
# changed (rather than only scoring newly-available forecast/target pairs).
RESCORE <- FALSE
# Relative tolerance used to detect a changed observation when RESCORE = TRUE
SCORE_TOLERANCE <- 1e-2

# =============================================================================

dir.create(dirname(TARGETS_FILE), recursive = TRUE, showWarnings = FALSE)
readr::read_csv(TARGETS_URL) |>
  mutate(datetime = as_datetime(datetime)) |>
  mutate(depth = ifelse(variable != "temperature", NA, depth)) |>
  readr::write_csv(TARGETS_FILE)

con <- duckdbfs::cached_connection(tempfile())

obs_key_cols <- c("project_id", "site_id", "datetime", "duration", "variable", "depth")
score_key_cols <- c(obs_key_cols, "model_id", "family", "reference_datetime")

### Access the targets, forecasts, and scores subsets
targets <-
  duckdbfs::open_dataset(TARGETS_FILE,
               recursive = FALSE,
               format = "csv",
               parser_options = list(nullstr = "NA"),
               anonymous = TRUE) |>
  filter(!is.na(observation))


# No point in trying to score any forecasts still in future (relative to last observed)
# (pull forces eval, can take a minute)
last_observed_date <- targets |> select(datetime) |> distinct() |>
  filter(datetime == max(datetime)) |> pull(datetime)

forecasts <-
  duckdbfs::open_dataset(FORECASTS_S3_PATH,
               s3_endpoint = S3_ENDPOINT,
               anonymous=TRUE) |>
  filter(datetime <= {last_observed_date},
         !is.na(model_id),
         !is.na(parameter),
         !is.na(prediction)) |>
  # if necessary, enforce naming convention on "family" to avoid perpetual rescoring
  mutate(family = ifelse(family == 'ensemble', "sample", family),
         duration = "P1D",
         site_id = SITE_ID) |>
  # enforce horizon filter
  mutate(horizon = date_diff('day', as.POSIXct(reference_datetime), as.POSIXct(datetime)))

scores <- tryCatch(
  duckdbfs::open_dataset(SCORES_S3_PATH,
               s3_endpoint = S3_ENDPOINT, anonymous=TRUE) |>
    filter(!is.na(observation)),
  error = function(e) {
    message("No existing scores found, starting fresh")
    NULL
  }
)


if(RESCORE) {
  print("rescoring changed observations")
  # drop rows from scores if the scores and targets disagree on "observation"
  scores <- scores |>
    inner_join(targets, by = obs_key_cols) |>
    filter( abs(observation.x - observation.y)/observation.x < {SCORE_TOLERANCE})
}



## INSTEAD, we pull our subset to local disk first.
## This looks silly but is much better for RAM and speed!!

  unlink(TEMP_DIR, recursive = TRUE)
  dir.create(TEMP_DIR, recursive = T, showWarnings = F)

  forecasts |>
    mutate(depth = ifelse(is.na(depth), -9999, depth)) |>
    group_by(site_id) |>
    duckdbfs::write_dataset(file.path(TEMP_DIR, "forecasts"))

  if(!is.null(scores)){
  scores  |>
      mutate(depth = ifelse(is.na(depth), -9999, depth)) |>
      group_by(site_id) |>
      duckdbfs::write_dataset(file.path(TEMP_DIR, "scores"))
  }

  targets |>
    mutate(depth = ifelse(is.na(depth), -9999, depth)) |>
    group_by(site_id) |>
    duckdbfs::write_dataset(file.path(TEMP_DIR, "targets"))

  forecasts <- duckdbfs::open_dataset(file.path(TEMP_DIR, "forecasts", "**"))
  if(!is.null(scores)) scores <- duckdbfs::open_dataset(file.path(TEMP_DIR, "scores", "**"))
  targets <- duckdbfs::open_dataset(file.path(TEMP_DIR, "targets", "**"))

## Magic rock&roll time: Subset unscored + targets available:
print("Compute who needs to be scored...")
if(is.null(scores)){
  forecasts |>
    inner_join(targets) |> # forecast has targets available
    group_by(site_id) |>
    duckdbfs::write_dataset(file.path(TEMP_DIR, "score_me"))
}else{
  forecasts |>
    anti_join(select(scores, all_of(score_key_cols))) |> # forecast is unscored
    inner_join(targets) |> # forecast has targets available
    group_by(site_id) |>
    duckdbfs::write_dataset(file.path(TEMP_DIR, "score_me"))
}

duckdbfs::close_connection(con)
gc()

score_group <- function(i, groups) {

  # if we want to clear connection manually we need to re-open fc.  Maybe not necessary
  source(SCORE_FUNCTION_SCRIPT)
  con <- duckdbfs::cached_connection(tempfile())

  tryCatch({

  fc <- duckdbfs::open_dataset(file.path(TEMP_DIR, "score_me"))
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
  path <- glue::glue("{SCORES_S3_PATH}/site_id={site_id}/variable={var}/model_id={model}")
  path2 <- glue::glue("{SCORES_OSN_PATH}/site_id={site_id}/variable={var}/model_id={model}")

  log <- glue::glue("Joining to existing scores of variable {var} for model {model}")
  message(log)
  #readr::write_lines(log, "new-scoring.log", append=TRUE)

  file_exist <- length(mc_ls(path2))

  duckdbfs::duckdb_secrets(endpoint = S3_ENDPOINT,
                           key = Sys.getenv("AWS_ACCESS_KEY_ID"),
                           secret = Sys.getenv("AWS_SECRET_ACCESS_KEY"),
                           bucket = SCORES_S3_SUBPATH)

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
    duckdbfs::write_dataset(SCORES_S3_PATH)

  }, finally = {
    duckdbfs::close_connection(con)
    gc()
  })
}

fc <- duckdbfs::open_dataset(file.path(TEMP_DIR, "score_me")) |>
  filter(!is.na(model_id))
groups <- fc |> distinct(site_id, variable, model_id, family) |> collect()
total <- nrow(groups)

print("Computing new scores....")
pb <- progress_bar$new(format = "  scoring [:bar] :percent in :elapsed",
                       total = total, clear = FALSE, width= 60)

# If we have lots to score this can take a while
for (i in seq_len(total)) {
  pb$tick()
  print(paste("Scoring model:", groups$model_id[i], "variable:", groups$variable[i]))
  score_group(i, groups)

}
