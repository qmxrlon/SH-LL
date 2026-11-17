#!/usr/bin/env bats
#
# Tests for linux/sh-ll.sh. All system data comes from fixtures so the
# results are the same on every machine.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SHLL="$ROOT/linux/sh-ll.sh"
    FIX="$BATS_TEST_DIRNAME/fixtures"

    export SHLL_PROC_ROOT="$FIX/proc"
    export SHLL_ETC_ROOT="$FIX/etc"
    export SHLL_DF_FILE="$FIX/df.txt"
    export SHLL_SYSTEMD_DIR="$BATS_TEST_TMPDIR/no-systemd"
    export NO_COLOR=1
}

# --- command line ---------------------------------------------------------

@test "--version prints the version and exits 0" {
    run "$SHLL" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^sh-ll\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "--help prints usage and exits 0" {
    run "$SHLL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unknown option exits 3 (UNKNOWN)" {
    run "$SHLL" --bogus
    [ "$status" -eq 3 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "invalid format exits 3" {
    run "$SHLL" --format xml
    [ "$status" -eq 3 ]
}

@test "non-numeric threshold exits 3" {
    run "$SHLL" --disk-warn abc
    [ "$status" -eq 3 ]
}

@test "warning threshold above critical threshold exits 3" {
    run "$SHLL" --mem-warn 90 --mem-crit 80
    [ "$status" -eq 3 ]
}

@test "missing option value exits 3" {
    run "$SHLL" --output
    [ "$status" -eq 3 ]
}

# --- inventory ------------------------------------------------------------

@test "json output is valid and contains the fixture inventory" {
    run "$SHLL" --format json --disk-warn 90 --disk-crit 95
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
        .status == "OK"
        and .host.hostname == "testhost"
        and .host.os == "TestOS 1.0 & <LTS>"
        and .host.uptime_seconds == 93784
        and .cpu.model == "Test CPU 3000"
        and .cpu.cores == 4
        and .cpu.load == [0.40, 0.80, 1.20]
        and .memory.total_mb == 8000
        and .memory.used_percent == 50
        and .network.gateway == "192.168.1.1"
        and .network.dns == ["192.168.1.1", "1.1.1.1"]
        and .failed_services == null'
}

@test "pseudo filesystems such as tmpfs are not reported" {
    run "$SHLL" --format json
    echo "$output" | jq -e '[.disks[].mount] == ["/", "/data"]'
}

@test "listening ports are read from /proc and deduplicated" {
    run "$SHLL" --format json
    echo "$output" | jq -e '.listening_ports == ["tcp/22", "tcp/8080", "udp/53"]'
}

# --- checks and exit codes ------------------------------------------------

@test "disk above warning threshold returns WARNING (1)" {
    run "$SHLL" --format json
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "WARNING"
        and (.checks[] | select(.name == "disk /data") | .status) == "WARNING"
        and (.checks[] | select(.name == "disk /") | .status) == "OK"'
}

@test "disk at critical threshold returns CRITICAL (2)" {
    run "$SHLL" --format json --disk-warn 80 --disk-crit 85
    [ "$status" -eq 2 ]
    echo "$output" | jq -e '.status == "CRITICAL"'
}

@test "memory threshold is evaluated" {
    run "$SHLL" --format json --disk-warn 90 --disk-crit 95 --mem-warn 40 --mem-crit 60
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '(.checks[] | select(.name == "memory") | .status) == "WARNING"'
}

@test "load is compared per CPU core" {
    # 0.80 load on 4 cores = 0.20 per core
    run "$SHLL" --format json --disk-warn 90 --disk-crit 95 --load-warn 0.2 --load-crit 0.5
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '(.checks[] | select(.name == "load") | .status) == "WARNING"'
}

@test "unreadable meminfo makes the result UNKNOWN (3)" {
    local proc="$BATS_TEST_TMPDIR/proc"
    cp -r "$FIX/proc" "$proc"
    rm "$proc/meminfo"
    SHLL_PROC_ROOT="$proc" run "$SHLL" --format json --disk-warn 90 --disk-crit 95
    [ "$status" -eq 3 ]
    echo "$output" | jq -e '.status == "UNKNOWN"'
}

@test "failed systemd units raise a WARNING" {
    mkdir -p "$BATS_TEST_TMPDIR/systemd" "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/bin/sh
echo "nginx.service loaded failed failed A high performance web server"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" SHLL_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd" \
        run "$SHLL" --format json --disk-warn 90 --disk-crit 95
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.failed_services == ["nginx.service"]
        and (.checks[] | select(.name == "services") | .status) == "WARNING"'
}

# --- output formats -------------------------------------------------------

@test "quiet mode prints one Nagios-style line with perfdata" {
    run "$SHLL" --quiet
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" =~ ^SH-LL\ WARNING\ -\ 0\ critical,\ 1\ warning ]]
    [[ "$output" == *"| 'disk_/'=42%;80;90;0;100"* ]]
    [[ "$output" == *"mem=50%;85;95;0;100"* ]]
}

@test "text output lists all sections" {
    run "$SHLL"
    [[ "$output" == *"SH-LL System Report"* ]]
    [[ "$output" == *"testhost"* ]]
    [[ "$output" == *"Checks"* ]]
    [[ "$output" == *"Overall: WARNING"* ]]
    # no escape codes when NO_COLOR is set
    [[ "$output" != *$'\e['* ]]
}

@test "html report is written to a file with escaped content" {
    local out="$BATS_TEST_TMPDIR/report.html"
    run "$SHLL" --format html --output "$out"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    grep -q '<!DOCTYPE html>' "$out"
    grep -q 'TestOS 1.0 &amp; &lt;LTS&gt;' "$out"
    ! grep -q '<LTS>' "$out"
}

@test "unwritable output file exits 3" {
    run "$SHLL" --output /nonexistent-dir/report.txt
    [ "$status" -eq 3 ]
}
