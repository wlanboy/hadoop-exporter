#!/bin/bash
# Baut ein komplett offline-lauffaehiges Bundle des hadoop_exporter
# (https://github.com/vqcuong/hadoop_exporter), das auf einem Zielserver ohne
# pip/Internetzugang nur mit python3 gestartet werden kann.
#
# Muss auf einer Maschine MIT Internet-/Nexus-Zugriff laufen (nicht auf dem
# Zielserver). Siehe readme.md fuer den vollstaendigen Ablauf.

set -euo pipefail

# ---------------------------------------------------------------------------
# Konfiguration (per CLI-Flag ueberschreibbar, siehe --help)
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/vqcuong/hadoop_exporter.git"
REPO_REF="master"
SRC_DIR=""                      # falls gesetzt: lokal bereits vorhandener Checkout, kein git clone
PY_VERSION="3.11"                # Python-Version auf dem Zielserver (python3 --version)
PY_ABI="cp311"                    # zugehoeriger ABI-Tag (3.11 -> cp311, 3.9 -> cp39, ...)
ARCH="x86_64"                     # uname -m auf dem Zielserver
INDEX_URL="${PIP_INDEX_URL:-}"    # internes Artifactory/Nexus PyPI-Mirror
REQUIREMENTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/requirements-offline.txt"
TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
OUT_DIR="$(pwd)/dist"
WORK_DIR=""

usage() {
    cat <<EOF
Usage: $0 [Optionen]

  --index-url URL      PyPI-Index-URL, z.B. internes Nexus/Artifactory Mirror
                        (optional; ohne diese Option bzw. PIP_INDEX_URL nutzt
                        pip seine Standardkonfiguration, z.B. pypi.org oder
                        ~/.pip/pip.conf)
  --py-version X.Y      Python-Version des Zielservers (default: ${PY_VERSION})
  --abi TAG              ABI-Tag dazu, z.B. cp311, cp39, cp312 (default: ${PY_ABI})
  --arch ARCH            uname -m des Zielservers: x86_64 | aarch64 (default: ${ARCH})
  --repo-url URL          Git-URL des hadoop_exporter Quellcodes
  --ref REF               Git branch/tag/commit (default: ${REPO_REF})
  --src-dir DIR           Bereits vorhandener lokaler Checkout statt git clone
                          (nuetzlich, falls auch github.com nicht erreichbar ist)
  --requirements FILE     Alternative requirements-offline.txt
  --out DIR               Zielverzeichnis fuer das fertige tar.gz (default: ./dist)
  -h, --help              Diese Hilfe anzeigen
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --index-url) INDEX_URL="$2"; shift 2 ;;
        --py-version) PY_VERSION="$2"; shift 2 ;;
        --abi) PY_ABI="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --ref) REPO_REF="$2"; shift 2 ;;
        --src-dir) SRC_DIR="$2"; shift 2 ;;
        --requirements) REQUIREMENTS_FILE="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "FEHLER: python3 wird auf dem Build-Rechner benoetigt (fuer pip download)." >&2
    exit 1
fi

if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "FEHLER: 'python3 -m pip' funktioniert nicht auf dem Build-Rechner." >&2
    echo "        Dieses Script braucht pip NUR hier zum Herunterladen der Wheels," >&2
    echo "        nicht auf dem Zielserver. Installieren z.B. mit:" >&2
    echo "          python3 -m ensurepip --upgrade" >&2
    echo "        oder ueber den Paketmanager (z.B. 'dnf install python3-pip')." >&2
    exit 1
fi

case "${ARCH}" in
    x86_64)  PLATFORMS=(manylinux2014_x86_64 manylinux_2_17_x86_64 manylinux_2_28_x86_64) ;;
    aarch64) PLATFORMS=(manylinux2014_aarch64 manylinux_2_17_aarch64 manylinux_2_28_aarch64) ;;
    *) echo "FEHLER: unbekannte Architektur '${ARCH}' (erwartet x86_64|aarch64)" >&2; exit 1 ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

BUNDLE_DIR="${WORK_DIR}/hadoop_exporter_offline"
mkdir -p "${BUNDLE_DIR}"/{vendor,app,config,logs}

echo "==> Quellcode besorgen"
if [[ -n "${SRC_DIR}" ]]; then
    [[ -d "${SRC_DIR}" ]] || { echo "FEHLER: --src-dir '${SRC_DIR}' existiert nicht" >&2; exit 1; }
    cp -a "${SRC_DIR}" "${WORK_DIR}/src"
else
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${WORK_DIR}/src"
fi
SRC_COMMIT="$(git -C "${WORK_DIR}/src" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "==> App-Code kopieren (service.py, hadoop_exporter/, metrics/)"
cp "${WORK_DIR}/src/service.py" "${BUNDLE_DIR}/app/"
cp -r "${WORK_DIR}/src/hadoop_exporter" "${BUNDLE_DIR}/app/"
cp -r "${WORK_DIR}/src/metrics" "${BUNDLE_DIR}/app/"
chmod +x "${BUNDLE_DIR}/app/service.py"

echo "==> Wheels fuer Python ${PY_VERSION} / ${PY_ABI} / ${ARCH} laden${INDEX_URL:+ (Index: ${INDEX_URL})}"
WHEEL_DIR="${WORK_DIR}/wheelhouse"
mkdir -p "${WHEEL_DIR}"

PLATFORM_ARGS=()
for p in "${PLATFORMS[@]}"; do
    PLATFORM_ARGS+=(--platform "$p")
done

INDEX_ARGS=()
if [[ -n "${INDEX_URL}" ]]; then
    INDEX_ARGS+=(--index-url "${INDEX_URL}")
fi

python3 -m pip download \
    "${INDEX_ARGS[@]}" \
    --only-binary=:all: \
    --python-version "${PY_VERSION}" \
    --implementation cp \
    --abi "${PY_ABI}" \
    "${PLATFORM_ARGS[@]}" \
    -d "${WHEEL_DIR}" \
    -r "${REQUIREMENTS_FILE}"

echo "==> Wheels nach vendor/ entpacken (kein pip auf dem Zielserver noetig)"
for whl in "${WHEEL_DIR}"/*.whl; do
    python3 -m zipfile -e "${whl}" "${BUNDLE_DIR}/vendor/"
done

echo "==> Vorlagen (start.sh, config, systemd-Unit) einfuegen"
cp "${TEMPLATES_DIR}/start.sh" "${BUNDLE_DIR}/start.sh"
chmod +x "${BUNDLE_DIR}/start.sh"
cp "${TEMPLATES_DIR}/config.yaml.example" "${BUNDLE_DIR}/config/config.yaml.example"
cp "${TEMPLATES_DIR}/hadoop_exporter.service" "${BUNDLE_DIR}/hadoop_exporter.service"

cat > "${BUNDLE_DIR}/VERSION.txt" <<EOF
hadoop_exporter offline bundle
source:        ${REPO_URL} @ ${REPO_REF} (${SRC_COMMIT})
built:         $(date -u +%FT%TZ)
target python: ${PY_VERSION} (${PY_ABI})
target arch:   ${ARCH}
requirements:  $(basename "${REQUIREMENTS_FILE}")
EOF

mkdir -p "${OUT_DIR}"
ARCHIVE="${OUT_DIR}/hadoop_exporter_offline_$(date +%Y%m%d).tar.gz"
tar -C "${WORK_DIR}" -czf "${ARCHIVE}" "$(basename "${BUNDLE_DIR}")"
sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"

echo
echo "==> Fertig: ${ARCHIVE}"
echo "    Pruefsumme: ${ARCHIVE}.sha256"
echo "    Naechste Schritte siehe readme.md"
