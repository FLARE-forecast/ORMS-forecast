library(tidyverse)
library(arrow)

#Set this starting date of your forecast
focal_datetime <- as_datetime("2026-06-23 00:00:00")

#Use these models for the short-term forecast
model_identifier <- c("flare_glm_v4_ecmwf_ifs025","flare_glm_v4_gefs_seamless")
#This this model for the seasonal forecast
model_identifier <- "flare_glm_v4_ecmwf_seasonal"

forecast_schema <- schema(
  reference_datetime = timestamp(unit = "us", timezone = "UTC"),
  datetime            = timestamp(unit = "us", timezone = "UTC"),
  pub_datetime         = timestamp(unit = "us", timezone = "UTC"),
  depth                = float64(),
  family               = utf8(),
  parameter            = utf8(),
  variable             = utf8(),
  prediction           = float64(),
  forecast             = float64(),
  variable_type        = utf8(),
  log_weight           = float64(),
  model_id             = utf8(),
  reference_date       = utf8()
)

s3 <- arrow::s3_bucket('bio230121-bucket01/flare/forecasts/parquet/site_id=ORMS', endpoint_override = 'amnh1.osn.mghpcc.org', anonymous = TRUE)

forecast <- arrow::open_dataset(s3, schema = forecast_schema) |>
  mutate(parameter = as.character(parameter)) |>
  filter(reference_datetime == focal_datetime,
         model_id %in% model_identifier,
         variable == "prob_mixed_density") |>
  collect() |>
  lubridate::with_tz(datetime, tzone = "Europe/Paris") |>
  lubridate::with_tz(reference_datetime, tzone = "Europe/Paris") |>
  mutate(model_id = ifelse(model_id == "flare_glm_v4_ecmwf_ifs025", "FLARE + ECMWF IFS", model_id),
         model_id = ifelse(model_id == "flare_glm_v4_gefs_seamless", "FLARE + NCEP GEFS",model_id))

datetimes <- round_date(seq(min(forecast$datetime), max(forecast$datetime), by = "3 days"), unit = "day")
all_datetimes <- round_date(seq(min(forecast$datetime), max(forecast$datetime), by = "1 days"), unit = "day")
all_datetimes <- all_datetimes[!(all_datetimes %in% datetimes)]

ggplot(forecast, aes(x = datetime, y = prediction, color = model_id)) +
  geom_line() +
  geom_vline(aes(xintercept = reference_datetime)) +
  theme_bw() +
  labs(title = "Probability that lake is mixed", y = "Probability", color = "Model") +
  ylim(0,1.0) +
  scale_x_datetime(breaks = datetimes, minor_breaks = all_datetimes) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1),
        panel.background = element_rect(fill = "#F2F2F2",color = "#F2F2F2"),
        plot.background = element_rect(fill = "#F2F2F2",color = "#F2F2F2"),
        legend.background = element_rect(fill = "#F2F2F2",color = "#F2F2F2"),
        legend.position = "bottom")
