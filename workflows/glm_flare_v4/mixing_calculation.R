library(tidyverse)
library(arrow)

df <- open_dataset("forecasts/parquet/") |>
  filter(reference_datetime == as_date("2021-06-01"),
         variable == "temperature",
         site_id == "ORMS") |>
  collect()

prob_mix <- df |>
  select(reference_datetime, datetime, depth, parameter, prediction) |>
  filter(depth %in% c(0.5, 5.0)) |>
  pivot_wider(names_from = depth, values_from = prediction) |>
  mutate(mixed = ifelse(abs(`0.5` - `5`) < 1.0, 1, 0)) |>
  group_by(datetime, reference_datetime) |>
  summarize(prob_mix = sum(mixed)/ n(), .groups = "drop_last")

ggplot(prob_mix, aes(x = datetime, y = prob_mix)) +
  geom_line() +
  geom_vline(aes(xintercept = reference_datetime)) +
  theme_bw()


