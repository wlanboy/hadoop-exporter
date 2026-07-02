#!/bin/bash
# Prueft ein mit build_offline_bundle.sh gebautes Bundle lokal, BEVOR es auf
# den echten offline Zielserver kopiert wird:
#   - entpackt das Bundle in ein Temp-Verzeichnis
#   - startet start.sh in einer bewusst "leeren" Umgebung (env -i), damit
#     wirklich nur das Bundle selbst benutzt wird und keine ambienten
#     venvs/PYTHONPATH/pip-Installationen des Testrechners mitspielen
#   - wartet, bis /metrics antwortet, und prueft den Inhalt
#   - raeumt danach automatisch auf (Prozess killen, Temp-Verzeichnis loeschen)
#
# So simuliert dieses Script moeglichst nah den offline Red Hat Server: nur
# python3, sonst nichts.

set -euo pipefail

PORT=9123
BUNDLE=""

usage() {
    cat <<EOF
Usage: $0 [tar.gz-Datei] [--port PORT]

  tar.gz-Datei   Von build_offline_bundle.sh erzeugtes Bundle
                 (default: neuestes dist/hadoop_exporter_offline_*.tar.gz)
  --port PORT    Testport (default: ${PORT})
  -h, --help     Diese Hilfe anzeigen
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) BUNDLE="$1"; shift ;;
    esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${BUNDLE}" ]]; then
    BUNDLE="$(ls -t "${DIR}"/dist/hadoop_exporter_offline_*.tar.gz 2>/dev/null | head -n1 || true)"
fi

if [[ -z "${BUNDLE}" || ! -f "${BUNDLE}" ]]; then
    echo "FEHLER: kein Bundle gefunden. Erst ./build_offline_bundle.sh ausfuehren" >&2
    echo "        oder Pfad zum tar.gz als Argument uebergeben." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
PID=""

cleanup() {
    if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
        kill "${PID}" 2>/dev/null || true
        wait "${PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "==> Entpacke ${BUNDLE}"
tar xzf "${BUNDLE}" -C "${WORK_DIR}"
BUNDLE_DIR="$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n1)"

if [[ -z "${BUNDLE_DIR}" ]]; then
    echo "FEHLER: konnte entpackten Bundle-Ordner nicht finden" >&2
    exit 1
fi

cp "${BUNDLE_DIR}/config/config.yaml.example" "${BUNDLE_DIR}/config/config.yaml"
sed -i "s/^\(\s*address:\).*/\1 127.0.0.1/" "${BUNDLE_DIR}/config/config.yaml"
sed -i "s/^\(\s*port:\).*/\1 ${PORT}/" "${BUNDLE_DIR}/config/config.yaml"

echo "==> Starte start.sh in isolierter Umgebung (env -i, kein ambientes venv/PYTHONPATH)"
env -i \
    PATH="/usr/bin:/bin" \
    HOME="${HOME}" \
    EXPORTER_CONFIG="${BUNDLE_DIR}/config/config.yaml" \
    EXPORTER_LOGS_DIR="${WORK_DIR}/logs" \
    "${BUNDLE_DIR}/start.sh" > "${WORK_DIR}/test.log" 2>&1 &
PID=$!

echo "==> Warte auf http://127.0.0.1:${PORT}/metrics ..."
READY=0
for _ in $(seq 1 30); do
    if ! kill -0 "${PID}" 2>/dev/null; then
        echo "FEHLER: Prozess ist vorzeitig beendet. Log:" >&2
        cat "${WORK_DIR}/test.log" >&2
        exit 1
    fi
    if curl -s -o "${WORK_DIR}/metrics.out" -w '%{http_code}' "http://127.0.0.1:${PORT}/metrics" 2>/dev/null | grep -q '^200$'; then
        READY=1
        break
    fi
    sleep 0.5
done

if [[ "${READY}" -ne 1 ]]; then
    echo "FEHLER: /metrics hat innerhalb von 15s nicht mit HTTP 200 geantwortet. Log:" >&2
    cat "${WORK_DIR}/test.log" >&2
    exit 1
fi

if ! grep -q '^# HELP ' "${WORK_DIR}/metrics.out"; then
    echo "FEHLER: Antwort sieht nicht wie Prometheus-Metrics aus:" >&2
    head -5 "${WORK_DIR}/metrics.out" >&2
    exit 1
fi

echo
echo "==> OK: Bundle startet mit reinem python3 (ohne pip/venv) und liefert Metrics."
echo "    Beispielzeilen:"
grep '^# HELP ' "${WORK_DIR}/metrics.out" | head -3
echo
echo "Hinweis: Warnungen zu 'NameResolutionError' im Log sind erwartet, da die"
echo "Beispiel-JMX-URLs aus config.yaml.example nicht real aufloesbar sind."
