# SH-LL – System Health & Inventory

[![CI](https://github.com/qmxrlon/SH-LL/actions/workflows/ci.yml/badge.svg)](https://github.com/qmxrlon/SH-LL/actions/workflows/ci.yml)

SH-LL erfasst die wichtigsten Daten eines Rechners (Betriebssystem, CPU, Arbeitsspeicher, Datenträger, Netzwerk, offene Ports, ausgefallene Dienste) und prüft sie gegen einstellbare Schwellwerte. Es gibt eine Bash-Version für Linux und eine PowerShell-Version für Windows. Beide liefern dasselbe JSON-Format.

Typische Einsätze:

- **Inventarisierung:** schneller Überblick über einen Server oder Client als Text, JSON oder HTML-Bericht
- **Monitoring:** Exit-Codes und Ausgabe nach der Nagios/Icinga-Plugin-Konvention, direkt als Check einsetzbar
- **Automatisierung:** JSON-Ausgabe zur Weiterverarbeitung (z. B. `jq`, Ansible, eigene Skripte)

## Funktionen

| Bereich       | Linux (`linux/sh-ll.sh`)                        | Windows (`windows/sh-ll.ps1`)                     |
|---------------|-------------------------------------------------|---------------------------------------------------|
| System        | Hostname, Distribution, Kernel, Uptime          | Hostname, Windows-Edition, Version, Uptime        |
| CPU           | Modell, Kerne, Load Average (1/5/15 min)        | Modell, logische Kerne, Auslastung in %           |
| Speicher      | belegt/gesamt (aus `MemAvailable`)              | belegt/gesamt                                     |
| Datenträger   | alle echten Dateisysteme (ohne tmpfs etc.)      | alle lokalen Laufwerke                            |
| Netzwerk      | Interfaces, MAC, IPv4, Gateway, DNS             | Adapter, MAC, IPv4, Gateway, DNS                  |
| Ports         | lauschende TCP/UDP-Ports (direkt aus `/proc`)   | lauschende TCP/UDP-Ports                          |
| Dienste       | fehlgeschlagene systemd-Units                   | gestoppte Dienste mit Starttyp „Automatisch“      |

**Checks:** Füllstand pro Datenträger, Speicherauslastung, Last pro CPU-Kern (Linux) bzw. CPU-Auslastung (Windows), Dienste.

Die Linux-Version braucht nur Bash und Standardwerkzeuge (`awk`, `df`). `ss`, `netstat` oder `ip` sind nicht nötig.

## Verwendung

### Linux

```bash
chmod +x linux/sh-ll.sh

./linux/sh-ll.sh                               # Textbericht
./linux/sh-ll.sh --format json                 # JSON
./linux/sh-ll.sh --format html -o report.html  # HTML-Bericht
./linux/sh-ll.sh --quiet                       # eine Statuszeile für Monitoring
./linux/sh-ll.sh --disk-warn 70 --disk-crit 85 # eigene Schwellwerte
```

| Option                    | Standard | Bedeutung                              |
|---------------------------|----------|----------------------------------------|
| `-f`, `--format`          | `text`   | `text`, `json` oder `html`             |
| `-o`, `--output`          | stdout   | Bericht in Datei schreiben             |
| `-q`, `--quiet`           |          | eine Zeile mit Performance-Daten       |
| `--disk-warn/--disk-crit` | 80 / 90  | Datenträger-Füllstand in %             |
| `--mem-warn/--mem-crit`   | 85 / 95  | Speicherauslastung in %                |
| `--load-warn/--load-crit` | 1.0 / 2.0| 5-Minuten-Load pro CPU-Kern            |

### Windows

```powershell
.\windows\sh-ll.ps1                                  # Textbericht
.\windows\sh-ll.ps1 -Format json                     # JSON
.\windows\sh-ll.ps1 -Format html -OutputPath report.html
.\windows\sh-ll.ps1 -Quiet -DiskWarn 70 -DiskCrit 85
.\windows\sh-ll.ps1 -ExcludeService 'MyTriggerService'
```

Läuft mit Windows PowerShell 5.1 und PowerShell 7. Falls die Ausführungsrichtlinie das Skript blockiert:
`powershell -ExecutionPolicy Bypass -File .\windows\sh-ll.ps1`

Parameter: `-Format`, `-OutputPath`, `-Quiet`, `-DiskWarn/-DiskCrit` (80/90), `-MemWarn/-MemCrit` (85/95), `-CpuWarn/-CpuCrit` (80/95), `-ExcludeService`.

Dienste wie `gupdate`, `edgeupdate` oder `sppsvc` stehen auf „Automatisch“, laufen aber nur bei Bedarf. Sie sind standardmäßig ausgenommen, damit der Dienste-Check nicht ständig warnt. Mit `-ExcludeService` lässt sich die Liste anpassen (Wildcards erlaubt).

## Exit-Codes

| Code | Status   | Bedeutung                                         |
|------|----------|---------------------------------------------------|
| 0    | OK       | alle Checks in Ordnung                            |
| 1    | WARNING  | mindestens ein Warnschwellwert erreicht           |
| 2    | CRITICAL | mindestens ein kritischer Schwellwert erreicht    |
| 3    | UNKNOWN  | Daten nicht lesbar oder ungültige Parameter       |

Der schlechteste Einzelstatus bestimmt das Gesamtergebnis (CRITICAL vor WARNING vor UNKNOWN).

## Beispiele aus dem Betrieb

**Icinga 2 / Nagios-Check** (Ausgabe mit `--quiet`):

```
SH-LL WARNING - 0 critical, 1 warning, 4 checks | 'disk_/'=42%;80;90;0;100 'disk_/data'=85%;80;90;0;100 mem=50%;85;95;0;100 load_per_core=0.20;1.0;2.0;0
```

```
object CheckCommand "sh-ll" {
  command = [ "/opt/sh-ll/linux/sh-ll.sh", "--quiet" ]
  arguments = {
    "--disk-warn" = "$shll_disk_warn$"
    "--disk-crit" = "$shll_disk_crit$"
  }
}
```

**Täglicher HTML-Bericht per cron:**

```cron
0 7 * * * /opt/sh-ll/linux/sh-ll.sh --format html -o /var/www/reports/$(hostname).html
```

**Windows-Aufgabenplanung:**

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Tools\sh-ll\windows\sh-ll.ps1 -Format html -OutputPath C:\Reports\health.html'
$trigger = New-ScheduledTaskTrigger -Daily -At 7am
Register-ScheduledTask -TaskName 'SH-LL Report' -Action $action -Trigger $trigger
```

**Auswertung mit jq**, z. B. alle Datenträger über 80 %:

```bash
./linux/sh-ll.sh -f json | jq -r '.disks[] | select(.used_percent > 80) | "\(.mount): \(.used_percent)%"'
```

## JSON-Format

Beide Versionen liefern dieselbe Struktur (gekürzt):

```json
{
  "tool": "sh-ll",
  "version": "1.0.0",
  "timestamp": "2026-11-17T07:00:00Z",
  "status": "WARNING",
  "host":    { "hostname": "srv01", "platform": "linux", "os": "Ubuntu 24.04 LTS", "kernel": "6.8.0", "uptime_seconds": 93784 },
  "cpu":     { "model": "...", "cores": 4, "load": [0.4, 0.8, 1.2] },
  "memory":  { "total_mb": 8000, "used_mb": 4000, "used_percent": 50 },
  "disks":   [ { "mount": "/", "filesystem": "ext4", "size_mb": 100000, "used_mb": 42000, "used_percent": 42 } ],
  "network": { "interfaces": [ ... ], "ipv4_all": [ ... ], "gateway": "192.168.1.1", "dns": [ "192.168.1.1" ] },
  "listening_ports": [ "tcp/22", "udp/53" ],
  "failed_services": [],
  "checks":  [ { "name": "disk /", "status": "OK", "message": "42% used" } ]
}
```

Unterschiede: Windows liefert bei `cpu` den Wert `load_percent` statt `load` und zusätzlich ein Feld `errors` mit Fehlern bei der Datenerfassung. `failed_services` ist `null`, wenn kein systemd verfügbar ist (z. B. in Containern).

## Tests

```bash
# Linux: ShellCheck + bats
shellcheck linux/sh-ll.sh
bats tests/sh-ll.bats

# PowerShell: Check-Logik und Ausgabeformate (läuft auf jedem System mit pwsh),
# auf Windows zusätzlich ein echter Durchlauf gegen den Rechner
pwsh -File tests/sh-ll.Tests.ps1
```

Die Linux-Tests lesen ihre Systemdaten aus `tests/fixtures/`. Dafür lassen sich die Datenquellen über `SHLL_PROC_ROOT`, `SHLL_ETC_ROOT`, `SHLL_DF_FILE` und `SHLL_SYSTEMD_DIR` umlenken. So sind die Ergebnisse auf jeder Maschine gleich.

GitHub Actions führt bei jedem Push ShellCheck und die bats-Tests unter Ubuntu aus, außerdem PSScriptAnalyzer und die PowerShell-Tests unter Windows (PowerShell 7 und 5.1).

## Projektstruktur

```
linux/sh-ll.sh            Bash-Version für Linux
windows/sh-ll.ps1         PowerShell-Version für Windows
tests/sh-ll.bats          Tests für die Linux-Version
tests/sh-ll.Tests.ps1     Tests für die Windows-Version
tests/fixtures/           feste Testdaten (/proc, /etc, df)
.github/workflows/ci.yml  CI für Linux und Windows
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
