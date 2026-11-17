#!/usr/bin/env bash
#
# SH-LL - System Health & Inventory for Linux
#
# Collects an inventory of the local machine (OS, CPU, memory, disks,
# network, listening ports, failed services) and evaluates health checks
# against configurable thresholds.
#
# Exit codes follow the Nagios/Icinga plugin convention:
#   0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN

set -uo pipefail

readonly VERSION="1.0.0"
readonly PROG="sh-ll"

# --- defaults -------------------------------------------------------------
FORMAT="text"
OUTPUT=""
QUIET=0
DISK_WARN=80
DISK_CRIT=90
MEM_WARN=85
MEM_CRIT=95
LOAD_WARN=1.0   # 5-minute load average per CPU core
LOAD_CRIT=2.0

# Data sources (overridable for testing)
PROC_ROOT="${SHLL_PROC_ROOT:-/proc}"
ETC_ROOT="${SHLL_ETC_ROOT:-/etc}"
SYSTEMD_DIR="${SHLL_SYSTEMD_DIR:-/run/systemd/system}"
DF_FILE="${SHLL_DF_FILE:-}"   # file with `df -PkT` output instead of running df

# --- helpers --------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $PROG [options]

Collects a system inventory and runs health checks.

Options:
  -f, --format FORMAT   Output format: text (default), json, html
  -o, --output FILE     Write the report to FILE instead of stdout
  -q, --quiet           Print a single Nagios-style status line with perfdata
      --disk-warn PCT   Disk usage warning threshold   (default: $DISK_WARN)
      --disk-crit PCT   Disk usage critical threshold  (default: $DISK_CRIT)
      --mem-warn PCT    Memory usage warning threshold (default: $MEM_WARN)
      --mem-crit PCT    Memory usage critical threshold(default: $MEM_CRIT)
      --load-warn N     5-min load per core, warning   (default: $LOAD_WARN)
      --load-crit N     5-min load per core, critical  (default: $LOAD_CRIT)
  -h, --help            Show this help
  -V, --version         Show version

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit 3
}

is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# float comparisons: fgt A B -> A > B, fge A B -> A >= B
fgt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }
fge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

html_escape() {
    local s=$1
    # Replacements are quoted: since bash 5.2 an unquoted "&" in the
    # replacement stands for the matched text (patsub_replacement).
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    s=${s//\"/"&quot;"}
    printf '%s' "$s"
}

# --- argument parsing -----------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--format)    [[ $# -ge 2 ]] || die "missing value for $1"; FORMAT=$2; shift 2 ;;
            -o|--output)    [[ $# -ge 2 ]] || die "missing value for $1"; OUTPUT=$2; shift 2 ;;
            -q|--quiet)     QUIET=1; shift ;;
            --disk-warn)    [[ $# -ge 2 ]] || die "missing value for $1"; DISK_WARN=$2; shift 2 ;;
            --disk-crit)    [[ $# -ge 2 ]] || die "missing value for $1"; DISK_CRIT=$2; shift 2 ;;
            --mem-warn)     [[ $# -ge 2 ]] || die "missing value for $1"; MEM_WARN=$2; shift 2 ;;
            --mem-crit)     [[ $# -ge 2 ]] || die "missing value for $1"; MEM_CRIT=$2; shift 2 ;;
            --load-warn)    [[ $# -ge 2 ]] || die "missing value for $1"; LOAD_WARN=$2; shift 2 ;;
            --load-crit)    [[ $# -ge 2 ]] || die "missing value for $1"; LOAD_CRIT=$2; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            -V|--version)   echo "$PROG $VERSION"; exit 0 ;;
            *)              die "unknown option: $1 (see --help)" ;;
        esac
    done

    case "$FORMAT" in text|json|html) ;; *) die "invalid format: $FORMAT" ;; esac

    local v
    for v in DISK_WARN DISK_CRIT MEM_WARN MEM_CRIT LOAD_WARN LOAD_CRIT; do
        is_number "${!v}" || die "threshold ${v,,} must be a non-negative number, got '${!v}'"
    done
    fgt "$DISK_WARN" "$DISK_CRIT" && die "--disk-warn must not exceed --disk-crit"
    fgt "$MEM_WARN" "$MEM_CRIT"   && die "--mem-warn must not exceed --mem-crit"
    fgt "$LOAD_WARN" "$LOAD_CRIT" && die "--load-warn must not exceed --load-crit"
}

# --- data collection ------------------------------------------------------

collect_host() {
    HOSTNAME_VAL=$(cat "$PROC_ROOT/sys/kernel/hostname" 2>/dev/null || hostname 2>/dev/null || echo unknown)
    OS_NAME="unknown"
    if [[ -r "$ETC_ROOT/os-release" ]]; then
        OS_NAME=$(awk -F= '$1=="PRETTY_NAME" { gsub(/^"|"$/, "", $2); print $2 }' "$ETC_ROOT/os-release")
        [[ -n "$OS_NAME" ]] || OS_NAME="unknown"
    fi
    KERNEL=$(uname -r 2>/dev/null || echo unknown)
    UPTIME_S=$(awk '{ printf "%d", $1 }' "$PROC_ROOT/uptime" 2>/dev/null || echo 0)
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
}

collect_cpu() {
    CPU_MODEL=$(awk -F': ' '/^model name/ { print $2; exit }' "$PROC_ROOT/cpuinfo" 2>/dev/null)
    [[ -n "$CPU_MODEL" ]] || CPU_MODEL="unknown"
    CPU_CORES=$(grep -c '^processor' "$PROC_ROOT/cpuinfo" 2>/dev/null)
    [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]] || CPU_CORES=$(nproc 2>/dev/null || echo 1)
    read -r LOAD1 LOAD5 LOAD15 _ < "$PROC_ROOT/loadavg" 2>/dev/null || { LOAD1=0; LOAD5=0; LOAD15=0; }
    LOAD_PER_CORE=$(awk -v l="$LOAD5" -v c="$CPU_CORES" 'BEGIN { printf "%.2f", l / c }')
}

collect_memory() {
    local total avail
    total=$(awk '/^MemTotal:/ { print $2 }' "$PROC_ROOT/meminfo" 2>/dev/null)
    avail=$(awk '/^MemAvailable:/ { print $2 }' "$PROC_ROOT/meminfo" 2>/dev/null)
    if [[ -z "$total" || "$total" -eq 0 ]]; then
        MEM_TOTAL_MB=0; MEM_USED_MB=0; MEM_PCT=0; MEM_OK=0
        return
    fi
    [[ -n "$avail" ]] || avail=$(awk '/^(MemFree|Buffers|Cached):/ { s += $2 } END { print s }' "$PROC_ROOT/meminfo")
    MEM_TOTAL_MB=$(( total / 1024 ))
    MEM_USED_MB=$(( (total - avail) / 1024 ))
    MEM_PCT=$(( (total - avail) * 100 / total ))
    MEM_OK=1
}

# Fills DISK_* arrays. Pseudo and read-only image filesystems are skipped.
collect_disks() {
    DISK_MOUNT=(); DISK_FS=(); DISK_SIZE=(); DISK_USED=(); DISK_PCT=()
    local type size used pct mount
    while read -r _ type size used _ pct mount; do
        case "$type" in
            tmpfs|devtmpfs|squashfs|proc|sysfs|efivarfs|devpts|cgroup*|nsfs|ramfs) continue ;;
        esac
        [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || continue
        DISK_MOUNT+=("$mount")
        DISK_FS+=("$type")
        DISK_SIZE+=("$(( size / 1024 ))")
        DISK_USED+=("$(( used / 1024 ))")
        DISK_PCT+=("${pct%\%}")
    done < <(if [[ -n "$DF_FILE" ]]; then cat "$DF_FILE"; else df -PkT 2>/dev/null; fi | tail -n +2)
}

hex_to_ipv4() {
    local h=$1
    printf '%d.%d.%d.%d' "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}"
}

collect_network() {
    NET_IF=(); NET_STATE=(); NET_MAC=(); NET_IPV4=()
    local path name addrs
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        name=${path##*/}
        [[ "$name" == "lo" ]] && continue
        addrs=""
        if command -v ip >/dev/null 2>&1; then
            addrs=$(ip -4 -o addr show dev "$name" 2>/dev/null | awk '{ print $4 }' | paste -sd' ' -)
        fi
        NET_IF+=("$name")
        NET_STATE+=("$(cat "$path/operstate" 2>/dev/null || echo unknown)")
        NET_MAC+=("$(cat "$path/address" 2>/dev/null || echo unknown)")
        NET_IPV4+=("$addrs")
    done
    # Fallback when iproute2 is not installed: all addresses, not per interface
    IPV4_ALL=$(hostname -I 2>/dev/null | xargs || true)

    GATEWAY=""
    if [[ -r "$PROC_ROOT/net/route" ]]; then
        local gw
        gw=$(awk 'NR > 1 && $2 == "00000000" { print $3; exit }' "$PROC_ROOT/net/route")
        [[ -n "$gw" ]] && GATEWAY=$(hex_to_ipv4 "$gw")
    fi

    DNS_SERVERS=()
    if [[ -r "$ETC_ROOT/resolv.conf" ]]; then
        mapfile -t DNS_SERVERS < <(awk '$1 == "nameserver" { print $2 }' "$ETC_ROOT/resolv.conf")
    fi
}

# Reads listening sockets straight from /proc so no ss/netstat is required.
collect_ports() {
    PORTS=()
    local file proto state_listen hexport
    for file in tcp tcp6 udp udp6; do
        [[ -r "$PROC_ROOT/net/$file" ]] || continue
        proto=${file%6}
        # TCP LISTEN = 0A, unbound UDP sockets show state 07
        [[ "$proto" == "tcp" ]] && state_listen="0A" || state_listen="07"
        # awk prints the hex port; bash converts it (mawk lacks strtonum)
        while read -r hexport; do
            PORTS+=("$proto/$((16#$hexport))")
        done < <(awk -v st="$state_listen" 'NR > 1 && $4 == st {
                    n = split($2, a, ":"); print a[n] }' \
                 "$PROC_ROOT/net/$file" 2>/dev/null)
    done
    if [[ ${#PORTS[@]} -gt 0 ]]; then
        mapfile -t PORTS < <(printf '%s\n' "${PORTS[@]}" | sort -t/ -k1,1 -k2,2n -u)
    fi
}

collect_services() {
    FAILED_SERVICES=()
    SYSTEMD=0
    if [[ -d "$SYSTEMD_DIR" ]] && command -v systemctl >/dev/null 2>&1; then
        SYSTEMD=1
        mapfile -t FAILED_SERVICES < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }')
    fi
}

# --- checks ---------------------------------------------------------------

CHECK_NAME=(); CHECK_STATUS=(); CHECK_MSG=(); PERFDATA=()

add_check() {
    CHECK_NAME+=("$1"); CHECK_STATUS+=("$2"); CHECK_MSG+=("$3")
}

level() {
    local value=$1 warn=$2 crit=$3
    if fge "$value" "$crit"; then echo CRITICAL
    elif fge "$value" "$warn"; then echo WARNING
    else echo OK
    fi
}

run_checks() {
    local i st
    for i in "${!DISK_MOUNT[@]}"; do
        st=$(level "${DISK_PCT[$i]}" "$DISK_WARN" "$DISK_CRIT")
        add_check "disk ${DISK_MOUNT[$i]}" "$st" "${DISK_PCT[$i]}% used"
        PERFDATA+=("'disk_${DISK_MOUNT[$i]}'=${DISK_PCT[$i]}%;$DISK_WARN;$DISK_CRIT;0;100")
    done

    if [[ "$MEM_OK" -eq 1 ]]; then
        st=$(level "$MEM_PCT" "$MEM_WARN" "$MEM_CRIT")
        add_check "memory" "$st" "$MEM_PCT% used (${MEM_USED_MB}/${MEM_TOTAL_MB} MB)"
        PERFDATA+=("mem=${MEM_PCT}%;$MEM_WARN;$MEM_CRIT;0;100")
    else
        add_check "memory" "UNKNOWN" "could not read $PROC_ROOT/meminfo"
    fi

    st=$(level "$LOAD_PER_CORE" "$LOAD_WARN" "$LOAD_CRIT")
    add_check "load" "$st" "5-min load $LOAD5 on $CPU_CORES core(s) (${LOAD_PER_CORE}/core)"
    PERFDATA+=("load_per_core=$LOAD_PER_CORE;$LOAD_WARN;$LOAD_CRIT;0")

    if [[ "$SYSTEMD" -eq 1 ]]; then
        if [[ ${#FAILED_SERVICES[@]} -eq 0 ]]; then
            add_check "services" "OK" "no failed systemd units"
        else
            add_check "services" "WARNING" "${#FAILED_SERVICES[@]} failed: ${FAILED_SERVICES[*]}"
        fi
        PERFDATA+=("failed_units=${#FAILED_SERVICES[@]};1;;0")
    fi

    OVERALL="OK"
    local s
    for s in "${CHECK_STATUS[@]}"; do
        case "$s" in
            CRITICAL) OVERALL="CRITICAL" ;;
            WARNING)  [[ "$OVERALL" == "CRITICAL" ]] || OVERALL="WARNING" ;;
            UNKNOWN)  [[ "$OVERALL" == "OK" ]] && OVERALL="UNKNOWN" ;;
        esac
    done
}

exit_code() {
    case "$OVERALL" in OK) echo 0 ;; WARNING) echo 1 ;; CRITICAL) echo 2 ;; *) echo 3 ;; esac
}

count_status() {
    local want=$1 n=0 s
    for s in "${CHECK_STATUS[@]}"; do [[ "$s" == "$want" ]] && n=$((n + 1)); done
    echo "$n"
}

# --- output ---------------------------------------------------------------

human_uptime() {
    local s=$1
    printf '%dd %dh %dm' $((s / 86400)) $((s % 86400 / 3600)) $((s % 3600 / 60))
}

json_array() {
    local first=1 item
    printf '['
    for item in "$@"; do
        [[ $first -eq 1 ]] || printf ','
        printf '"%s"' "$(json_escape "$item")"
        first=0
    done
    printf ']'
}

render_json() {
    local i
    printf '{\n'
    printf '  "tool": "%s",\n  "version": "%s",\n  "timestamp": "%s",\n' "$PROG" "$VERSION" "$TIMESTAMP"
    printf '  "status": "%s",\n' "$OVERALL"
    printf '  "host": {"hostname": "%s", "platform": "linux", "os": "%s", "kernel": "%s", "uptime_seconds": %d},\n' \
        "$(json_escape "$HOSTNAME_VAL")" "$(json_escape "$OS_NAME")" "$(json_escape "$KERNEL")" "$UPTIME_S"
    printf '  "cpu": {"model": "%s", "cores": %d, "load": [%s, %s, %s]},\n' \
        "$(json_escape "$CPU_MODEL")" "$CPU_CORES" "$LOAD1" "$LOAD5" "$LOAD15"
    printf '  "memory": {"total_mb": %d, "used_mb": %d, "used_percent": %d},\n' "$MEM_TOTAL_MB" "$MEM_USED_MB" "$MEM_PCT"

    printf '  "disks": ['
    for i in "${!DISK_MOUNT[@]}"; do
        [[ $i -eq 0 ]] || printf ','
        printf '\n    {"mount": "%s", "filesystem": "%s", "size_mb": %d, "used_mb": %d, "used_percent": %d}' \
            "$(json_escape "${DISK_MOUNT[$i]}")" "$(json_escape "${DISK_FS[$i]}")" \
            "${DISK_SIZE[$i]}" "${DISK_USED[$i]}" "${DISK_PCT[$i]}"
    done
    printf '\n  ],\n'

    printf '  "network": {\n    "interfaces": ['
    for i in "${!NET_IF[@]}"; do
        [[ $i -eq 0 ]] || printf ','
        # shellcheck disable=SC2086  # word splitting of the address list is intended
        printf '\n      {"name": "%s", "state": "%s", "mac": "%s", "ipv4": %s}' \
            "$(json_escape "${NET_IF[$i]}")" "$(json_escape "${NET_STATE[$i]}")" \
            "$(json_escape "${NET_MAC[$i]}")" "$(json_array ${NET_IPV4[$i]})"
    done
    printf '\n    ],\n'
    # shellcheck disable=SC2086
    printf '    "ipv4_all": %s,\n' "$(json_array $IPV4_ALL)"
    printf '    "gateway": "%s",\n' "$(json_escape "$GATEWAY")"
    printf '    "dns": %s\n  },\n' "$(json_array "${DNS_SERVERS[@]}")"

    printf '  "listening_ports": %s,\n' "$(json_array "${PORTS[@]}")"
    if [[ "$SYSTEMD" -eq 1 ]]; then
        printf '  "failed_services": %s,\n' "$(json_array "${FAILED_SERVICES[@]}")"
    else
        printf '  "failed_services": null,\n'
    fi

    printf '  "checks": ['
    for i in "${!CHECK_NAME[@]}"; do
        [[ $i -eq 0 ]] || printf ','
        printf '\n    {"name": "%s", "status": "%s", "message": "%s"}' \
            "$(json_escape "${CHECK_NAME[$i]}")" "${CHECK_STATUS[$i]}" "$(json_escape "${CHECK_MSG[$i]}")"
    done
    printf '\n  ]\n}\n'
}

render_text() {
    local c_ok="" c_warn="" c_crit="" c_dim="" c_bold="" c_reset=""
    if [[ -z "$OUTPUT" && -t 1 && -z "${NO_COLOR:-}" ]]; then
        c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_crit=$'\e[31m'; c_dim=$'\e[2m'; c_bold=$'\e[1m'; c_reset=$'\e[0m'
    fi
    colorize() {
        case "$1" in
            OK) printf '%s%-8s%s' "$c_ok" "$1" "$c_reset" ;;
            WARNING) printf '%s%-8s%s' "$c_warn" "$1" "$c_reset" ;;
            *) printf '%s%-8s%s' "$c_crit" "$1" "$c_reset" ;;
        esac
    }

    local i
    printf '%sSH-LL System Report%s  %s%s%s\n\n' "$c_bold" "$c_reset" "$c_dim" "$TIMESTAMP" "$c_reset"
    printf '%sHost%s\n' "$c_bold" "$c_reset"
    printf '  %-12s %s\n' "Hostname" "$HOSTNAME_VAL" "OS" "$OS_NAME" "Kernel" "$KERNEL" "Uptime" "$(human_uptime "$UPTIME_S")"
    printf '\n%sCPU / Memory%s\n' "$c_bold" "$c_reset"
    printf '  %-12s %s\n' "CPU" "$CPU_MODEL ($CPU_CORES cores)" "Load" "$LOAD1 $LOAD5 $LOAD15" \
        "Memory" "${MEM_USED_MB} / ${MEM_TOTAL_MB} MB (${MEM_PCT}%)"

    printf '\n%sDisks%s\n' "$c_bold" "$c_reset"
    printf '  %-24s %-8s %10s %10s %6s\n' "Mount" "FS" "Size MB" "Used MB" "Use%"
    for i in "${!DISK_MOUNT[@]}"; do
        printf '  %-24s %-8s %10s %10s %5s%%\n' "${DISK_MOUNT[$i]}" "${DISK_FS[$i]}" "${DISK_SIZE[$i]}" "${DISK_USED[$i]}" "${DISK_PCT[$i]}"
    done

    printf '\n%sNetwork%s\n' "$c_bold" "$c_reset"
    for i in "${!NET_IF[@]}"; do
        printf '  %-12s %-8s %-18s %s\n' "${NET_IF[$i]}" "${NET_STATE[$i]}" "${NET_MAC[$i]}" "${NET_IPV4[$i]:--}"
    done
    [[ -n "$IPV4_ALL" ]] && printf '  %-12s %s\n' "IPv4 (all)" "$IPV4_ALL"
    printf '  %-12s %s\n' "Gateway" "${GATEWAY:--}" "DNS" "${DNS_SERVERS[*]:--}"
    printf '  %-12s %s\n' "Listening" "${PORTS[*]:--}"

    printf '\n%sChecks%s\n' "$c_bold" "$c_reset"
    for i in "${!CHECK_NAME[@]}"; do
        printf '  '; colorize "${CHECK_STATUS[$i]}"; printf ' %-26s %s\n' "${CHECK_NAME[$i]}" "${CHECK_MSG[$i]}"
    done
    printf '\nOverall: '; colorize "$OVERALL"; printf '\n'
}

render_html() {
    local i cls
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SH-LL Report - $(html_escape "$HOSTNAME_VAL")</title>
<style>
  body { font-family: system-ui, -apple-system, Segoe UI, sans-serif; margin: 2rem auto; max-width: 960px; padding: 0 1rem; color: #1f2328; }
  h1 { font-size: 1.5rem; margin-bottom: .25rem; }
  h2 { font-size: 1.1rem; margin-top: 2rem; border-bottom: 1px solid #d0d7de; padding-bottom: .3rem; }
  .meta { color: #656d76; font-size: .9rem; }
  table { border-collapse: collapse; width: 100%; font-size: .92rem; }
  th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #eaeef2; }
  th { background: #f6f8fa; }
  .badge { display: inline-block; padding: .1rem .5rem; border-radius: 1rem; font-weight: 600; font-size: .8rem; }
  .OK { background: #dafbe1; color: #116329; }
  .WARNING { background: #fff8c5; color: #7d4e00; }
  .CRITICAL { background: #ffebe9; color: #a40e26; }
  .UNKNOWN { background: #eaeef2; color: #424a53; }
  .bar { background: #eaeef2; border-radius: 4px; height: 8px; min-width: 120px; }
  .bar span { display: block; height: 8px; border-radius: 4px; background: #0969da; }
</style>
</head>
<body>
<h1>$(html_escape "$HOSTNAME_VAL") <span class="badge $OVERALL">$OVERALL</span></h1>
<div class="meta">Generated by $PROG $VERSION at $TIMESTAMP</div>

<h2>Host</h2>
<table>
<tr><th>Operating system</th><td>$(html_escape "$OS_NAME")</td></tr>
<tr><th>Kernel</th><td>$(html_escape "$KERNEL")</td></tr>
<tr><th>Uptime</th><td>$(human_uptime "$UPTIME_S")</td></tr>
<tr><th>CPU</th><td>$(html_escape "$CPU_MODEL") ($CPU_CORES cores)</td></tr>
<tr><th>Load (1/5/15)</th><td>$LOAD1 / $LOAD5 / $LOAD15</td></tr>
<tr><th>Memory</th><td>$MEM_USED_MB / $MEM_TOTAL_MB MB ($MEM_PCT%)</td></tr>
</table>

<h2>Checks</h2>
<table>
<tr><th>Status</th><th>Check</th><th>Details</th></tr>
EOF
    for i in "${!CHECK_NAME[@]}"; do
        printf '<tr><td><span class="badge %s">%s</span></td><td>%s</td><td>%s</td></tr>\n' \
            "${CHECK_STATUS[$i]}" "${CHECK_STATUS[$i]}" "$(html_escape "${CHECK_NAME[$i]}")" "$(html_escape "${CHECK_MSG[$i]}")"
    done
    printf '</table>\n\n<h2>Disks</h2>\n<table>\n<tr><th>Mount</th><th>Filesystem</th><th>Size MB</th><th>Used MB</th><th>Usage</th></tr>\n'
    for i in "${!DISK_MOUNT[@]}"; do
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><div class="bar"><span style="width:%s%%"></span></div> %s%%</td></tr>\n' \
            "$(html_escape "${DISK_MOUNT[$i]}")" "$(html_escape "${DISK_FS[$i]}")" "${DISK_SIZE[$i]}" "${DISK_USED[$i]}" "${DISK_PCT[$i]}" "${DISK_PCT[$i]}"
    done
    printf '</table>\n\n<h2>Network</h2>\n<table>\n<tr><th>Interface</th><th>State</th><th>MAC</th><th>IPv4</th></tr>\n'
    for i in "${!NET_IF[@]}"; do
        cls="${NET_IPV4[$i]:--}"
        printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(html_escape "${NET_IF[$i]}")" "$(html_escape "${NET_STATE[$i]}")" "$(html_escape "${NET_MAC[$i]}")" "$(html_escape "$cls")"
    done
    printf '</table>\n<table>\n'
    printf '<tr><th>Gateway</th><td>%s</td></tr>\n' "$(html_escape "${GATEWAY:--}")"
    printf '<tr><th>DNS servers</th><td>%s</td></tr>\n' "$(html_escape "${DNS_SERVERS[*]:--}")"
    printf '<tr><th>Listening ports</th><td>%s</td></tr>\n' "$(html_escape "${PORTS[*]:--}")"
    printf '</table>\n</body>\n</html>\n'
}

render_quiet() {
    printf 'SH-LL %s - %s critical, %s warning, %s checks | %s\n' \
        "$OVERALL" "$(count_status CRITICAL)" "$(count_status WARNING)" "${#CHECK_NAME[@]}" "${PERFDATA[*]}"
}

# --- main -----------------------------------------------------------------

main() {
    parse_args "$@"

    collect_host
    collect_cpu
    collect_memory
    collect_disks
    collect_network
    collect_ports
    collect_services
    run_checks

    local renderer="render_$FORMAT"
    [[ $QUIET -eq 1 ]] && renderer="render_quiet"

    if [[ -n "$OUTPUT" ]]; then
        "$renderer" > "$OUTPUT" || die "cannot write to $OUTPUT"
    else
        "$renderer"
    fi

    exit "$(exit_code)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
