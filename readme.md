# hadoop_exporter – Offline-Bundle ohne Docker

Baut [hadoop_exporter](https://github.com/vqcuong/hadoop_exporter) (Prometheus-Exporter
fuer HDFS/YARN/Hive-Metriken via JMX) so zusammen, dass er auf einem
**offline Red Hat Server** laeuft, der nur `python3` hat – kein `pip`, kein
Paketmanager, kein Internetzugang.

## Wie das funktioniert

Auf dem Zielserver koennen keine Pakete installiert werden. Deshalb wird auf
einer Maschine **mit** Internet-/Nexus-Zugriff ein vollstaendiges Bundle
gebaut:

- Der Code des Exporters (`service.py`, `hadoop_exporter/`, `metrics/`).
- Alle benoetigten Python-Abhaengigkeiten als bereits **entpackte** Wheels
  (`vendor/`) – kein `pip install` auf dem Zielserver noetig, nur
  `PYTHONPATH` setzen und `python3` starten.

Das Ergebnis ist ein `tar.gz`, das auf den Zielserver kopiert, entpackt und
per `start.sh` gestartet wird.

## Wichtiger Fund: `python-consul` fehlt absichtlich

Das offizielle `requirements.txt` des Projekts listet `python-consul`, weil
`Exporter.register_consul()` heisst. Tatsaechlich ruft diese Methode nur
`start_http_server(...)` auf (siehe `hadoop_exporter/exporter.py`) – es wird
**nirgendwo im Code** `consul` importiert oder verwendet. Der Name ist
irrefuehrend. Um das Offline-Bundle klein zu halten, wird `python-consul`
(und damit `six` als Transitivabhaengigkeit) bewusst **nicht** vendort.
Falls in Zukunft echte Consul-Registrierung eingebaut wird, muesste das
nachgezogen werden.

Tatsaechlich benoetigt werden nur:

- `requests` (JMX-Metriken per HTTP abrufen)
- `prometheus-client` (Metrics-HTTP-Server + Registry)
- `pyyaml` (Config- und Metrics-Mapping-Dateien parsen)

Siehe [requirements-offline.txt](requirements-offline.txt). Die Versionen
wurden gegenueber dem Original-`requirements.txt` angehoben (`pyyaml`
5.3.1 → 6.0.1, `requests` 2.23.0 → 2.31.0, `prometheus-client` 0.9.0 →
0.20.0), weil fuer die alten Pins keine Wheels fuer Python 3.11 existieren.
Die im Code genutzten APIs (`yaml.safe_load`, `requests.session().get()`,
`prometheus_client.start_http_server`/`GaugeMetricFamily`/`REGISTRY`) sind
in diesen Versionsspannen unveraendert.

## Dateien in diesem Repo

| Datei | Zweck |
|---|---|
| `build_offline_bundle.sh` | Baut das Bundle (laeuft auf dem Build-Rechner mit Internet/Nexus) |
| `requirements-offline.txt` | Tatsaechlich benoetigte Abhaengigkeiten (ohne `python-consul`) |
| `templates/start.sh` | Startskript, wird ins Bundle kopiert |
| `templates/config.yaml.example` | Beispiel-Konfiguration (JMX-Endpunkte) |
| `templates/hadoop_exporter.service` | Optionale systemd-Unit fuer den Zielserver |

## Voraussetzungen

**Build-Rechner** (mit Internetzugang, muss NICHT Red Hat sein):
- `python3` + `pip`
- `git`
- Zugriff auf einen PyPI-Index (direkt auf pypi.org oder ein internes
  Artifactory/Nexus-Mirror). Optional per `--index-url` uebergeben; ohne
  diese Option nutzt pip seine Standardkonfiguration (`PIP_INDEX_URL` /
  `~/.pip/pip.conf` bzw. pypi.org).

**Zielserver** (offline Red Hat):
- `python3` (getestet mit Python 3.11) – kein `pip`, keine sonstigen Pakete
- CPU-Architektur x86_64

> Wenn Python-Version oder Architektur des Zielservers abweichen: vorher auf
> dem Zielserver `python3 --version` und `uname -m` pruefen und die
> entsprechenden `--py-version` / `--abi` / `--arch` Flags am Buildscript
> anpassen (z.B. `--py-version 3.9 --abi cp39` fuer RHEL 9 Standard-Python).

## Ablauf

### 1. Bundle bauen (auf dem Build-Rechner)

Mit internem Nexus/Artifactory-Mirror:

```bash
./build_offline_bundle.sh \
  --index-url http://localhost:8081/repository/pypi-proxy/simple/  \
  --py-version 3.11 \
  --abi cp311 \
  --arch x86_64 \
  --src-dir ../hadoop_exporter
```

Mit direktem Internetzugang (kein `--index-url` noetig, pip nutzt dann seine
Standardkonfiguration bzw. pypi.org):

```bash
./build_offline_bundle.sh \
  --py-version 3.11 \
  --abi cp311 \
  --arch x86_64 \
  --src-dir ../hadoop_exporter
```

> Achtung bei mehrzeiligen Befehlen: **jede** Zeile ausser der letzten braucht
> ein `\` am Ende. Fehlt es (wie z.B. nach `--arch x86_64`), fuehrt die Shell
> die naechste Zeile als eigenes Kommando aus – daher Fehler wie
> `--src-dir: Befehl nicht gefunden`.

Das Script:
1. klont `hadoop_exporter` von GitHub (alternativ `--src-dir`, falls
   github.com vom Build-Rechner aus ebenfalls nicht erreichbar ist und der
   Code manuell heruntergeladen wurde),
2. laedt `requests`, `prometheus-client`, `pyyaml` inkl. transitiver
   Abhaengigkeiten (`urllib3`, `certifi`, `charset-normalizer`, `idna`) als
   vorkompilierte Wheels **fuer die Ziel-Plattform** herunter (auch wenn der
   Build-Rechner selbst eine andere Python-Version/Architektur hat),
3. entpackt die Wheels direkt nach `vendor/` (kein `pip install` noetig,
   einfaches Unzip),
4. kopiert Code + Vorlagen zusammen,
5. packt alles in `dist/hadoop_exporter_offline_<datum>.tar.gz` inkl.
   `.sha256`-Pruefsumme.

`--help` zeigt alle Optionen.

### 2. Auf den Zielserver kopieren

```bash
scp dist/hadoop_exporter_offline_<datum>.tar.gz* zielserver:/tmp/
ssh zielserver 'sha256sum -c /tmp/hadoop_exporter_offline_<datum>.tar.gz.sha256'
ssh zielserver 'mkdir -p /opt/hadoop_exporter && tar xzf /tmp/hadoop_exporter_offline_<datum>.tar.gz -C /opt/hadoop_exporter --strip-components=1'
```

### 3. Konfigurieren

```bash
ssh zielserver 'cp /opt/hadoop_exporter/config/config.yaml.example /opt/hadoop_exporter/config/config.yaml'
```

Danach `config/config.yaml` mit den echten JMX-URLs von NameNode, DataNode,
ResourceManager, NodeManager, HiveServer2 etc. anpassen (siehe Kommentare in
der Datei). Unterstuetzte `services`-Schluessel in dieser Version:
`namenode`, `datanode`, `journalnode`, `resourcemanager`, `nodemanager`,
`hiveserver2`.

### 4. Starten

```bash
ssh zielserver '/opt/hadoop_exporter/start.sh'
```

Test:

```bash
curl http://localhost:9123/metrics
```

`start.sh` setzt `PYTHONPATH` auf `vendor/` + `app/` und startet
`app/service.py` direkt mit dem System-`python3` – ohne venv, ohne `pip`.

### 5. Optional: als systemd-Service

```bash
ssh zielserver 'sudo cp /opt/hadoop_exporter/hadoop_exporter.service /etc/systemd/system/'
ssh zielserver 'sudo systemctl daemon-reload && sudo systemctl enable --now hadoop_exporter'
```

Pfad in der Unit-Datei anpassen, falls nicht nach `/opt/hadoop_exporter`
entpackt wurde.

## Troubleshooting

- **`No module named pip`** beim Bauen: Der Build-Rechner selbst braucht
  `pip` (nur dort, nicht auf dem Zielserver) zum Herunterladen der Wheels.
  Nachinstallieren z.B. mit `python3 -m ensurepip --upgrade` oder per
  Paketmanager (`dnf install python3-pip`).
- **`ImportError` / `undefined symbol` beim Start**: Python-Version oder
  Architektur des Zielservers weicht von `--py-version`/`--abi`/`--arch`
  beim Bauen ab. Bundle mit den korrekten Werten neu bauen.
- **PyYAML nutzt automatisch die reine Python-Variante**, falls die
  mitgelieferte C-Erweiterung (`_yaml`, gebuendelt mit `libyaml`) aus
  irgendeinem Grund nicht laedt – das ist ein eingebauter Fallback in
  PyYAML selbst und funktional unproblematisch, nur minimal langsamer.
- **Keine Metriken / `NameResolutionError` in den Logs**: normal, wenn die
  in `config.yaml` eingetragenen Hostnamen vom Zielserver aus nicht
  aufloesbar sind – DNS/`/etc/hosts` bzw. die JMX-URLs pruefen.
- **Port 9123 blockiert**: `server.port` in `config.yaml` anpassen und
  Firewall-Regel (`firewalld`) auf dem Zielserver ergaenzen.
