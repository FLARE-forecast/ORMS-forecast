library(tidyverse)
library(arrow)
source("workflows/reforecast/get_met.R")

# Stage 2 output layout (see get_stage_2() in get_met.py):
#   drivers/met/gefs-v12/stage2/reference_datetime=<date>/site_id=<site_id>/part-0.parquet
.stage2_downloaded_dates <- function(site_id, base_dir = file.path("drivers", "met", "gefs-v12", "stage2")) {
  part_files <- list.files(base_dir,
                           pattern = "^part-0\\.parquet$",
                           recursive = TRUE,
                           full.names = TRUE)
  part_files <- part_files[grepl(paste0("site_id=", site_id, "(/|$)"), part_files)]

  ref_dirs <- basename(dirname(dirname(part_files)))
  ref_dates <- sub("^reference_datetime=", "", ref_dirs)
  sort(lubridate::as_date(ref_dates))
}

all_dates <- seq.Date(as_date("2020-12-15"), as_date("2026-03-31"), by = "1 day")

bbox <- c(
  left =  9.633681651222531,
  bottom =  56.32512281611785,
  right = 9.645247335840416,
  top = 56.32726436739858)

site_id <- "ORMS"

already_downloaded <- .stage2_downloaded_dates(site_id)
message(length(already_downloaded), " stage 2 reference_datetime(s) already downloaded for site '", site_id, "'")

dates_to_download <- all_dates[!(all_dates %in% already_downloaded)]
message(length(dates_to_download), " of ", length(all_dates), " stage 2 reference_datetime(s) remain to be downloaded")

for(i in seq_along(dates_to_download)){

  start_date <- dates_to_download[i]

  message(start_date)

  .run_get_met_py(
    stage = "stage2",
    site_id = site_id,
    bbox = bbox,
    reference_datetime = start_date)

}

.run_get_met_py(
  stage = "stage3",
  site_id = site_id,
  bbox = bbox,
  reference_datetime = min(all_dates),
  end_date = max(all_dates)
)

.run_get_met_py(
  stage = "stage3_update",
  site_id = site_id,
  bbox = bbox,
  reference_datetime = as_date("2020-08-15"),
  end_date = Sys.Date()
)


df <- open_dataset("drivers/met/gefs-v12/stage3/site_id=ORMS") |>
  summarize(max = max(datetime, na.rm = TRUE),
                   min = min(datetime, na.rm = TRUE)) |>
  collect()


df <- open_dataset("drivers/met/gefs-v12/stage3/site_id=ORMS") |>
  filter(as_date(datetime) == as_date("2026-08-01")) |>
  collect()

df |>
  ggplot(aes(x = datetime, y = prediction)) +
  geom_line() +
  facet_wrap(~variable, scales = "free_y")
