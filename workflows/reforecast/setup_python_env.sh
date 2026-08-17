#!/usr/bin/env bash
# Create/repair the dedicated Python virtual environment used by get_met.py.
#
# get_met.R (.ensure_met_python_env) creates this same venv automatically,
# but it runs pip with --quiet and only reports the exit code, which hides
# the actual pip error. Run this script directly to see full pip output
# when the R-driven setup fails (e.g. "No matching distribution found").
#
# Usage:
#   workflows/reforecast/setup_python_env.sh          # create/update the venv
#   workflows/reforecast/setup_python_env.sh --force   # wipe and rebuild it
#
# Override which interpreter is used to create the venv with:
#   PYTHON_BIN=/path/to/python3 workflows/reforecast/setup_python_env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="$PROJECT_ROOT/.venv-met"
MARKER_FILE="$VENV_DIR/packages_installed.txt"
# Keep this in sync with `required_marker` in workflows/reforecast/get_met.R
MARKER_VALUE="packages-v2"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Keep this in sync with the `packages` list in .ensure_met_python_env()
# (workflows/reforecast/get_met.R)
PACKAGES=(
  "dask==2025.1.0"
  "xarray[complete]==2026.1.0"
  "zarr>=3.2,<4"
  "certifi"
  "numpy"
  "pandas"
  "pyarrow"
  "requests"
  "aiohttp"
  "dynamical-catalog"
)

if [[ "${1:-}" == "--force" ]]; then
  echo "Removing existing environment at $VENV_DIR ..."
  rm -rf "$VENV_DIR"
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$PYTHON_BIN' was not found on PATH. Install Python 3, or set" >&2
  echo "PYTHON_BIN to the interpreter you want to use." >&2
  exit 1
fi

echo "Using interpreter: $("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"
echo "Python version:    $("$PYTHON_BIN" --version)"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment at $VENV_DIR ..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == CYGWIN* ]]; then
  VENV_PYTHON="$VENV_DIR/Scripts/python.exe"
else
  VENV_PYTHON="$VENV_DIR/bin/python3"
fi

echo "Upgrading pip ..."
"$VENV_PYTHON" -m pip install --upgrade pip

echo "Installing required packages (this will print full pip output) ..."
"$VENV_PYTHON" -m pip install "${PACKAGES[@]}"

echo "$MARKER_VALUE" > "$MARKER_FILE"

echo ""
echo "Done. Python environment ready at: $VENV_DIR"
echo "get_met.R will reuse this environment automatically."
