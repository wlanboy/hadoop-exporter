#!/bin/bash
# Startet den hadoop_exporter komplett offline: keine pip/venv-Aktivierung
# noetig, da vendor/ bereits fertig entpackte Packages enthaelt.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PYTHONPATH="${DIR}/vendor:${DIR}/app${PYTHONPATH:+:${PYTHONPATH}}"
export EXPORTER_METRICS_DIR="${EXPORTER_METRICS_DIR:-${DIR}/app/metrics}"
export EXPORTER_LOGS_DIR="${EXPORTER_LOGS_DIR:-${DIR}/logs}"
export EXPORTER_CONFIG="${EXPORTER_CONFIG:-${DIR}/config/config.yaml}"

mkdir -p "${EXPORTER_LOGS_DIR}"

exec python3 "${DIR}/app/service.py" "$@"
