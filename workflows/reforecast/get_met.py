################################################################################
# Download meteorological forecast data from dynamical.org and format it for
# FLARE. This is a pure-Python port of the original get_met.R (which relied on
# reticulate to drive Python from R). Doing the xarray/zarr/pandas work in
# native Python avoids reticulate/virtualenv version mismatches between
# machines -- this script is called as a subprocess from R (see R/get_met.R).
#
# stage 2 (future forecast): https://dynamical.org/catalog/noaa-gefs-forecast-35-day/
# stage 3 (historical):      https://dynamical.org/catalog/noaa-gefs-analysis/
# stage 3 update: like stage 3, but only downloads/merges in the datetimes
# missing from an already-downloaded stage 3 parquet
################################################################################
import argparse
import os

import certifi
import dynamical_catalog
import numpy as np
import pandas as pd

# variables of interest in the dynamical.org GEFS zarr store
VARS = [
    "temperature_2m",
    "relative_humidity_2m",
    "pressure_surface",
    "wind_u_10m",
    "wind_v_10m",
    "downward_long_wave_radiation_flux_surface",
    "downward_short_wave_radiation_flux_surface",
    "precipitation_surface",
]

# rename GEFS variable names to the names FLARE expects
VAR_RENAME = {
    "temperature_2m": "air_temperature",
    "relative_humidity_2m": "relative_humidity",
    "pressure_surface": "air_pressure",
    "wind_u_10m": "eastward_wind",
    "wind_v_10m": "northward_wind",
    "downward_long_wave_radiation_flux_surface": "surface_downwelling_longwave_flux_in_air",
    "downward_short_wave_radiation_flux_surface": "surface_downwelling_shortwave_flux_in_air",
    "precipitation_surface": "precipitation_flux",
}

STATE_VARS = [
    "air_pressure",
    "relative_humidity",
    "air_temperature",
    "eastward_wind",
    "northward_wind",
]

FLUX_VARS = [
    "precipitation_flux",
    "surface_downwelling_longwave_flux_in_air",
    "surface_downwelling_shortwave_flux_in_air",
]

FINAL_COLS = ["site_id", "family", "parameter", "datetime", "variable", "prediction"]


################################################################################
# solar geometry helpers (ported from R/to_hourly.R)
################################################################################
def equation_of_time(doy):
    f = np.pi / 180 * (279.5 + 0.9856 * doy)
    et = (
        -104.7 * np.sin(f)
        + 596.2 * np.sin(2 * f)
        + 4.3 * np.sin(4 * f)
        - 429.3 * np.cos(f)
        - 2 * np.cos(2 * f)
        + 19.3 * np.cos(3 * f)
    ) / 3600
    return et


def cos_solar_zenith_angle(doy, lat, lon, dt, hr):
    et = equation_of_time(doy)
    merid = np.floor(lon / 15) * 15
    if merid < 0:
        merid += 15
    lc = (lon - merid) * -4 / 60
    tz = merid / 360 * 24
    midbin = 0.5 * dt / 86400 * 24
    t0 = 12 + lc - et - tz - midbin
    h = np.pi / 12 * (hr - t0)
    dec = -23.45 * np.pi / 180 * np.cos(2 * np.pi * (doy + 10) / 365)
    cosz = np.sin(lat * np.pi / 180) * np.sin(dec) + np.cos(lat * np.pi / 180) * np.cos(dec) * np.cos(h)
    return np.where(cosz < 0, 0, cosz)


def downscale_solar_geom(doy, lon, lat):
    doy = np.asarray(doy, dtype=float)
    dt = np.median(np.diff(doy)) * 86400
    hr = (doy - np.floor(doy)) * 24
    cosz = cos_solar_zenith_angle(doy, lat, lon, dt, hr)
    return 1366 * cosz


################################################################################
# hourly downscaling (ported from get_hourly() in R/to_hourly.R)
################################################################################
def get_hourly(df, mean_lon, mean_lat):
    base = df[FINAL_COLS].copy()
    # GEFS values come back as float32; upcast so downstream calculations
    # (e.g. shortwave downscaling) don't overflow/raise on assignment
    base["prediction"] = base["prediction"].astype("float64")

    parameters = base["parameter"].unique()
    variables = base["variable"].unique()
    sites = base["site_id"].unique()
    datetime_range = pd.date_range(base["datetime"].min(), base["datetime"].max(), freq="1h")

    parameter_maxtime = (
        base.groupby(["site_id", "family", "parameter"])["datetime"]
        .max()
        .reset_index()
        .rename(columns={"datetime": "max_time"})
    )

    full_time = pd.MultiIndex.from_product(
        [sites, parameters, datetime_range, variables],
        names=["site_id", "parameter", "datetime", "variable"],
    ).to_frame(index=False)

    full_time = full_time.merge(parameter_maxtime, on=["site_id", "parameter"], how="left")
    full_time = full_time[full_time["datetime"] <= full_time["max_time"]]
    full_time = full_time.drop(columns=["max_time"]).drop_duplicates()

    join_keys = ["site_id", "parameter", "datetime", "family", "variable"]

    # states: linearly interpolated over time within each site/parameter/variable
    states = full_time.merge(base, on=join_keys, how="left")
    states = states[states["variable"].isin(STATE_VARS)].sort_values(["site_id", "parameter", "datetime"])
    states["prediction"] = states.groupby(["site_id", "parameter", "variable"])["prediction"].transform(
        lambda s: s.interpolate(method="linear", limit_direction="both")
    )
    states.loc[states["variable"] == "air_temperature", "prediction"] += 273
    # NOTE: raw GEFS temperature_2m from data.dynamical.org is in Celsius, so
    # the +273 converts to Kelvin (exactly once) for FLARE, which expects Kelvin.
    # The original R code checked `variable == "RH"`, a name that never
    # occurs after the rename above, so relative humidity is never divided by
    # 100 here. Preserved as-is for output parity with the legacy script.

    # fluxes: back-filled, then shortwave is downscaled using solar geometry
    fluxes = full_time.merge(base, on=join_keys, how="left")
    fluxes = fluxes[fluxes["variable"].isin(FLUX_VARS)].sort_values(["site_id", "family", "parameter", "datetime"])
    fluxes["prediction"] = fluxes.groupby(["site_id", "family", "parameter", "variable"])["prediction"].transform(
        lambda s: s.bfill()
    )
    # NOTE: dynamical.org's precipitation_surface is already a rate in
    # kg m-2 s-1 ("average precipitation rate since the previous forecast
    # step"), not a 6-hour accumulated depth, so no unit conversion is
    # needed here. (An earlier version of this code divided by 6*60*60,
    # which was carried over from a legacy 6-hourly-accumulated GEFS source
    # and made the output ~21,600x too small.)

    fluxes["hour"] = fluxes["datetime"].dt.hour
    fluxes["date"] = fluxes["datetime"].dt.date
    fluxes["doy"] = fluxes["datetime"].dt.dayofyear + fluxes["hour"] / 24
    fluxes["rpot"] = downscale_solar_geom(fluxes["doy"].to_numpy(), mean_lon, mean_lat)

    group_cols = ["site_id", "family", "parameter", "date", "variable"]
    fluxes["avg_sw"] = fluxes.groupby(group_cols)["prediction"].transform("mean")
    fluxes["avg_rpot"] = fluxes.groupby(group_cols)["rpot"].transform("mean")

    sw_mask = (fluxes["variable"] == "surface_downwelling_shortwave_flux_in_air") & (fluxes["avg_rpot"] > 0.0)
    fluxes.loc[sw_mask, "prediction"] = (
        fluxes.loc[sw_mask, "rpot"] * (fluxes.loc[sw_mask, "avg_sw"] / fluxes.loc[sw_mask, "avg_rpot"])
    )

    hourly_df = pd.concat([states[FINAL_COLS], fluxes[FINAL_COLS]], ignore_index=True)
    hourly_df = hourly_df.sort_values(["site_id", "family", "variable", "datetime"]).reset_index(drop=True)
    return hourly_df


################################################################################
# fetch + reformat one forecast cycle worth of met data
################################################################################
def get_temp_gefs(ds, site_id, start_time, bbox, lead_time=True, keep_only_day=True):
    lon_min, lat_min, lon_max, lat_max = bbox
    mean_lat = (lat_min + lat_max) / 2
    mean_lon = (lon_min + lon_max) / 2

    temp = ds[VARS].sel(
        init_time=str(start_time),
        latitude=mean_lat,
        longitude=mean_lon,
        method="nearest",
    )
    temp_r = temp.assign_coords(
        lead_hours=temp.lead_time.astype("timedelta64[h]").astype(int),
        member_id=temp.ensemble_member,
        init_time=temp.init_time,
    )

    if lead_time is not True:
        # NOTE: mirrors the original R logic (`lead_hours <= 86400`). Since
        # lead_hours is expressed in hours (max ~840 for a 35-day forecast)
        # this comparison never actually filters anything; preserved as-is
        # for output parity. The date filter at the end of this function is
        # what actually restricts stage 3 downloads to a single day.
        temp_r = temp_r.sel(lead_hours=temp_r.lead_hours <= 86400)

    df = temp_r.to_dataframe().reset_index()
    df = df.drop(
        columns=["expected_forecast_length", "ingested_forecast_length", "latitude", "longitude", "spatial_ref", "lead_hours"],
        errors="ignore",
    )

    id_vars = [c for c in df.columns if c not in VARS]
    temp_df = df.melt(id_vars=id_vars, value_vars=VARS, var_name="variable", value_name="prediction")
    temp_df["family"] = "ensemble"
    temp_df["site_id"] = site_id
    temp_df["init_time"] = pd.to_datetime(temp_df["init_time"]).dt.date
    temp_df = temp_df.rename(
        columns={"init_time": "reference_datetime", "valid_time": "datetime", "member_id": "parameter"}
    )
    temp_df["variable"] = temp_df["variable"].replace(VAR_RENAME)
    temp_df["datetime"] = pd.to_datetime(temp_df["datetime"], utc=True)
    temp_df["parameter"] = temp_df["parameter"].astype("float64")

    hourly_df = get_hourly(temp_df, mean_lon, mean_lat)
    if keep_only_day:
        hourly_df = hourly_df[hourly_df["datetime"].dt.date == pd.to_datetime(start_time).date()]
    return hourly_df


################################################################################
# stage 2: one parquet file per reference_datetime/site_id
################################################################################
def get_stage_2(ds, start_date, end_date, site, bbox, base_dir="drivers/met/gefs-v12/stage2"):
    dates = pd.date_range(start_date, end_date, freq="1D").date
    for date in dates:
        print(f"Downloading stage 2 met data for {date}", flush=True)
        # keep the full forecast lead time (the entire ~35-day GEFS cycle) so a
        # forecast launched at `date` is covered across its full horizon
        metdata = get_temp_gefs(ds, site, str(date), bbox, lead_time=True, keep_only_day=False).copy()
        metdata["reference_datetime"] = date
        for (ref_dt, site_id), group in metdata.groupby(["reference_datetime", "site_id"]):
            out_dir = os.path.join(base_dir, f"reference_datetime={ref_dt}", f"site_id={site_id}")
            os.makedirs(out_dir, exist_ok=True)
            group.drop(columns=["reference_datetime", "site_id"]).to_parquet(
                os.path.join(out_dir, "part-0.parquet"), index=False
            )
    print("Stage 2 data downloaded!")


################################################################################
# open the NOAA GEFS analysis dataset (single deterministic best-estimate
# time series at 3-hour resolution, no ensemble/forecast-cycle dimensions)
# https://dynamical.org/catalog/noaa-gefs-analysis/
################################################################################
def open_analysis_dataset():
    return dynamical_catalog.open("noaa-gefs-analysis", chunks=None)


################################################################################
# stage 3: historical met from start_date to end_date, one parquet file per
# site_id. Pulls from the GEFS *analysis* dataset instead of stitching
# together many separate forecast cycles from the 35-day forecast dataset:
# that let a single day of data (keep_only_day=True) cost as much as a full
# 35-day forecast cycle, because each day required its own zarr selection
# against a completely different forecast-cycle init. The analysis dataset
# has no forecast-cycle dimension, so the whole start_date..end_date window
# is fetched in a single selection.
################################################################################
def _download_stage_3_hourly(ds, start, end, site, bbox, n_members=31):
    lon_min, lat_min, lon_max, lat_max = bbox
    mean_lat = (lat_min + lat_max) / 2
    mean_lon = (lon_min + lon_max) / 2

    print(f"Downloading stage 3 (analysis) met data for {start} to {end}", flush=True)

    # the analysis dataset only has 3-hourly points (..., 18:00, 21:00), and
    # get_hourly() only interpolates up to the last actual sample it's given.
    # Without an anchor past 21:00 on `end`, hours 22:00/23:00 never get
    # interpolated and the output truncates at 21:00. Fetch one extra day so
    # the following day's 00:00 sample is available as that anchor, then trim
    # back down to `end` after interpolation (below).
    fetch_end = end + pd.Timedelta(days=1)

    # method="nearest" can't be combined with a sliced dimension in a single
    # .sel() call, so pick the point first and then slice time separately
    point = ds[VARS].sel(latitude=mean_lat, longitude=mean_lon, method="nearest")
    point = point.sel(time=slice(str(start), str(fetch_end)))

    df = point.to_dataframe().reset_index()
    df = df.drop(columns=["latitude", "longitude", "spatial_ref"], errors="ignore")

    id_vars = [c for c in df.columns if c not in VARS]
    long_df = df.melt(id_vars=id_vars, value_vars=VARS, var_name="variable", value_name="prediction")
    long_df["variable"] = long_df["variable"].replace(VAR_RENAME)
    long_df["datetime"] = pd.to_datetime(long_df["time"], utc=True)
    long_df["site_id"] = site
    long_df["family"] = "ensemble"
    long_df = long_df.drop(columns=["time"])

    # the analysis dataset is a single deterministic series with no ensemble
    # spread, but FLAREr's met-file builder joins historical met to the
    # future (stage 2) forecast by matching `parameter` per ensemble member.
    # Replicate the series across the same parameter ids stage 2 uses so
    # every ensemble member gets the same (correct) historical weather.
    members = pd.DataFrame({"parameter": np.arange(n_members, dtype="float64")})
    long_df = long_df.merge(members, how="cross")[FINAL_COLS]

    hourly_df = get_hourly(long_df, mean_lon, mean_lat)
    hourly_df = hourly_df[(hourly_df["datetime"].dt.date >= start) & (hourly_df["datetime"].dt.date <= end)]
    return hourly_df


def get_stage_3(ds, start_date, site, bbox, end_date=None, base_dir="drivers/met/gefs-v12/stage3", n_members=31):
    start = pd.to_datetime(start_date).date()
    if end_date is None:
        end = start + pd.Timedelta(days=5)
    else:
        end = pd.to_datetime(end_date).date()

    hourly_df = _download_stage_3_hourly(ds, start, end, site, bbox, n_members=n_members)

    for site_id, group in hourly_df.groupby("site_id"):
        out_dir = os.path.join(base_dir, f"site_id={site_id}")
        os.makedirs(out_dir, exist_ok=True)
        group.drop(columns=["site_id"]).to_parquet(os.path.join(out_dir, "part-0.parquet"), index=False)
    print("Stage 3 data downloaded!")


################################################################################
# stage 3 update: like stage 3, but only downloads the datetimes missing from
# an already-existing parquet (comparing against reference_datetime..end_date)
# and merges them in, instead of re-downloading the whole window every time.
################################################################################
def get_stage_3_update(ds, start_date, end_date, site, bbox, base_dir="drivers/met/gefs-v12/stage3", n_members=31):
    start = pd.to_datetime(start_date).date()
    if end_date is None:
        end = start + pd.Timedelta(days=5)
    else:
        end = pd.to_datetime(end_date).date()

    out_dir = os.path.join(base_dir, f"site_id={site}")
    met_file = os.path.join(out_dir, "part-0.parquet")

    if os.path.exists(met_file):
        existing_df = pd.read_parquet(met_file)
        existing_df["datetime"] = pd.to_datetime(existing_df["datetime"], utc=True)
        existing_datetimes = pd.DatetimeIndex(existing_df["datetime"].unique())
    else:
        existing_df = None
        existing_datetimes = pd.DatetimeIndex([], tz="UTC")

    requested = pd.date_range(
        pd.Timestamp(start, tz="UTC"), pd.Timestamp(end, tz="UTC") + pd.Timedelta(hours=23), freq="1h"
    )
    missing = requested.difference(existing_datetimes)

    if len(missing) == 0:
        print(f"No missing datetimes for site {site} between {start} and {end}; parquet already up to date.")
        return

    missing_start = missing.min().date()
    missing_end = missing.max().date()
    print(
        f"Found {len(missing)} missing datetime(s) for site {site} between {start} and {end}; "
        f"downloading {missing_start} to {missing_end}",
        flush=True,
    )

    new_hourly_df = _download_stage_3_hourly(ds, missing_start, missing_end, site, bbox, n_members=n_members)
    new_hourly_df = new_hourly_df.drop(columns=["site_id"])

    combined = new_hourly_df if existing_df is None else pd.concat([existing_df, new_hourly_df], ignore_index=True)

    # a datetime can appear in both existing_df and new_hourly_df if the
    # requested window overlaps already-downloaded data; keep the freshly
    # downloaded value in that case
    key_cols = ["family", "parameter", "datetime", "variable"]
    combined = combined.drop_duplicates(subset=key_cols, keep="last")
    combined = combined.sort_values(["datetime", "family", "parameter", "variable"]).reset_index(drop=True)

    os.makedirs(out_dir, exist_ok=True)
    combined.to_parquet(met_file, index=False)
    print(
        f"Stage 3 update complete for site {site}: parquet now spans "
        f"{combined['datetime'].min()} to {combined['datetime'].max()}."
    )


def main():
    parser = argparse.ArgumentParser(description="Download NOAA GEFS met forecasts for FLARE from dynamical.org")
    parser.add_argument("stage", choices=["stage2", "stage3", "stage3_update"])
    parser.add_argument("--site", required=True, help="site_id")
    parser.add_argument(
        "--bbox", required=True, nargs=4, type=float, metavar=("LEFT", "BOTTOM", "RIGHT", "TOP")
    )
    parser.add_argument("--start-date", required=True)
    parser.add_argument("--end-date", required=False, help="required for stage2; optional for stage3 (defaults to start+5 days)")
    args = parser.parse_args()

    # make sure http(s) access works regardless of the machine's default certs
    os.environ["SSL_CERT_FILE"] = certifi.where()

    if args.stage == "stage2":
        if not args.end_date:
            parser.error("--end-date is required for stage2")
        print("Opening the NOAA GEFS 35-day forecast dataset from dynamical.org")
        # data.dynamical.org hardcoded zarr URLs are deprecated (shut off
        # dataset-by-dataset through 2026-08-31); go through the catalog
        # instead, same as stage 3 -- see https://dynamical.org/migration-2026/
        ds = dynamical_catalog.open("noaa-gefs-forecast-35-day", chunks="auto")
        get_stage_2(ds, args.start_date, args.end_date, args.site, args.bbox)
    elif args.stage == "stage3":
        print("Opening the NOAA GEFS analysis dataset from dynamical.org")
        ds = open_analysis_dataset()
        get_stage_3(ds, args.start_date, args.site, args.bbox, end_date=args.end_date)
    else:
        print("Opening the NOAA GEFS analysis dataset from dynamical.org")
        ds = open_analysis_dataset()
        get_stage_3_update(ds, args.start_date, args.end_date, args.site, args.bbox)


if __name__ == "__main__":
    main()
