# Prototype water quality forecast for **Ormstrup Sø**

Automated near-term water quality forecasting system for **Ormstrup Sø** (Lake Ormstrup), Denmark (56.327°N, 9.645°E). The system couples the General Lake Model (GLM) with the Aquatic EcoDynamics (AED) library inside the FLARE (Forecasting Lake And Reservoir Ecosystems) framework to produce daily, 14-day ensemble forecasts of water temperature and water quality variables.

Forecasts are published to an S3-compatible object store and visualized through a Quarto dashboard deployed via GitHub Actions.

The dashboard is located at [flare-forecast.org/ORMS-forecast](http://flare-forecast.org/ORMS-forecast/ "http://flare-forecast.org/ORMS-forecast/")

## FLARE References

The forecasting system is built on the FLARE framework. Key papers describing the methodology:

- Thomas, R.Q., et al. (2020). A near-term iterative forecasting system successfully predicts reservoir hydrodynamics and partitions uncertainty in real time. *Water Resources Research*, 56, e2019WR026138. <https://doi.org/10.1029/2019WR026138>
- Carey, C.C., et al. (2022). Advancing lake and reservoir water quality management with near-term, iterative ecological forecasting. *Inland Waters*, 12(1), 107–120. <https://doi.org/10.1080/20442041.2020.1816421>
- Thomas, R.Q., et al. (2023). Near-term forecasts of NEON lakes reveal gradients of environmental predictability across the U.S. *Frontiers in Ecology and the Environment*, 21(5), 220–226. <https://doi.org/10.1002/fee.2623>
- Wander, H.L., et al. (2024). Data assimilation experiments inform monitoring needs for near-term ecological forecasts in a eutrophic reservoir. *Ecosphere*, 15, e4752. <https://doi.org/10.1002/ecs2.4752>

## Repository Structure

```         
ORMS-forecast-code/
├── configuration/
│   └── glm_flare_v4/               # Model and FLARE configuration files
│       ├── configure_run.yml        # Run-level settings: dates, horizon, sim name
│       ├── configure_flare_glm.yml  # FLARE settings: DA method, met/S3 sources, uncertainty
│       ├── configure_flare_glm_ecmwf_ifs025.yml  # Alternate config using ECMWF IFS 0.25° driver
│       ├── configure_run_ecmwf_ifs025.yml
│       ├── glm3.nml                 # GLM hydrodynamic model namelist
│       ├── aed2.nml                 # AED water quality model namelist
│       ├── observations_config_aed.csv       # Observation variable mapping
│       ├── states_config_aed.csv             # State variable configuration
│       └── parameter_calibration_config_aed.csv  # Parameters estimated by the EnKF
│
├── workflows/
│   └── glm_flare_v4/
│       ├── forecast_workflow.R      # Main forecast workflow (GEFS/OpenMeteo driver)
│       ├── forecast_workflow_ecmwf_ifs025.R  # Workflow using ECMWF IFS driver
│       └── add_metrics.R            # Post-processing: computes additional mixing metrics
│
├── dashboard/
│   ├── index.qmd                   # Quarto dashboard source (plots, maps, forecast panels)
│   ├── _quarto.yaml                # Quarto project configuration
│   ├── _brand.yaml                 # Brand colors and typography (VT/CEF theme)
│   ├── style.css                   # Additional CSS overrides
│   ├── style.scss                  # SCSS theme extensions
│   ├── sites.json                  # GeoJSON with monitoring site location
│   ├── install.R                   # R package installation script for dashboard deps
│   ├── vt_cef.jpg                  # Dashboard logo image
│
└── .github/
    └── workflows/
        ├── run_flare_v4.yml            # GitHub Actions: manually run daily GEFS forecast
        ├── forecasts_dashboard.yml     # GitHub Actions: run forecasts. Rebuild and deploy dashboard
        └── dashboard.yml               # GitHub Actions: manually rebuild and deploy dashboard
```

## How It Works

1.  **Data assimilation** — The system uses an Ensemble Kalman Filter (EnKF, 100 members) to assimilate in-situ water temperature observations from Ormstrup Sø, updating both model states and selected parameters.

2.  **Meteorological drivers** — Forecast periods use NCEP Global Ensemble Forecasting System (via OpenMeteo) for uncertainty propagation. An alternate configuration uses the ECMWF IFS 0.25° driver.

3.  **Forecast horizon** — 14-day probabilistic forecasts generated daily. Modeled depths span 0–6 m in 0.5 m increments.

4.  **Output** — Forecasts are written as Parquet files to an OSN (Open Storage Network) S3 bucket and visualized on the [Ormstrup Sø Water Quality Forecast Dashboard](https://flare-forecast.github.io/ORMS-forecast/).

5.  **Automation** — GitHub Actions workflows trigger the forecast run and dashboard rebuild on a daily schedule (or manually via `workflow_dispatch`).

## Running Locally

1.  Install R dependencies including `FLAREr`, `GLMAEDr`, `rLakeAnalyzer`, and `ropenmeteo`.
2.  Set AWS credentials for the OSN S3 endpoint (`amnh1.osn.mghpcc.org`).
3.  Source the appropriate workflow script:

``` r
source("workflows/glm_flare_v4/forecast_workflow.R")
```

To run the ECMWF IFS–driven configuration:

``` r
source("workflows/glm_flare_v4/forecast_workflow_ecmwf_ifs025.R")
```
