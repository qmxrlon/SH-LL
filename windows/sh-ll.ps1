<#
.SYNOPSIS
    SH-LL - System Health & Inventory for Windows.

.DESCRIPTION
    Collects an inventory of the local machine (OS, CPU, memory, volumes,
    network, listening ports, stopped automatic services) and evaluates
    health checks against configurable thresholds.

    Exit codes follow the Nagios/Icinga plugin convention:
    0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = UNKNOWN

    Compatible with Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    .\sh-ll.ps1
    Prints a text report.

.EXAMPLE
    .\sh-ll.ps1 -Format html -OutputPath report.html
    Writes an HTML report.

.EXAMPLE
    .\sh-ll.ps1 -Quiet -DiskWarn 70 -DiskCrit 85
    Prints a single monitoring status line with performance data.
#>
[CmdletBinding()]
param(
    # text, json or html
    [string]$Format = 'text',

    [string]$OutputPath,

    [switch]$Quiet,

    [double]$DiskWarn = 80,
    [double]$DiskCrit = 90,
    [double]$MemWarn = 85,
    [double]$MemCrit = 95,
    [double]$CpuWarn = 80,
    [double]$CpuCrit = 95,

    # Automatic services that are expected to be stopped most of the time
    # (trigger-start or update services). Wildcards are allowed.
    [string[]]$ExcludeService = @(
        'gupdate', 'gupdatem', 'GoogleUpdater*', 'edgeupdate', 'edgeupdatem',
        'MapsBroker', 'sppsvc', 'RemoteRegistry', 'TrustedInstaller',
        'ShellHWDetection', 'wuauserv', 'BITS', 'CDPSvc', 'WbioSrvc', 'tiledatamodelsvc'
    ),

    [switch]$Version
)

$ShllVersion = '1.0.0'

# --- data collection ------------------------------------------------------

function Get-ShllInventory {
    $inv = [ordered]@{
        host            = $null
        cpu             = $null
        memory          = $null
        disks           = @()
        network         = $null
        listening_ports = @()
        failed_services = $null
        errors          = @()
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $uptime = (Get-Date) - $os.LastBootUpTime
        $inv.host = [ordered]@{
            hostname       = $env:COMPUTERNAME
            platform       = 'windows'
            os             = "$($os.Caption)".Trim()
            kernel         = "$($os.Version)"
            uptime_seconds = [int64]$uptime.TotalSeconds
        }
        $totalKb = [double]$os.TotalVisibleMemorySize
        $freeKb = [double]$os.FreePhysicalMemory
        $inv.memory = [ordered]@{
            total_mb     = [int64]($totalKb / 1024)
            used_mb      = [int64](($totalKb - $freeKb) / 1024)
            used_percent = [int][math]::Floor(($totalKb - $freeKb) * 100 / $totalKb)
        }
    }
    catch {
        $inv.errors += "operating system: $($_.Exception.Message)"
        $inv.host = [ordered]@{ hostname = $env:COMPUTERNAME; platform = 'windows'; os = 'unknown'; kernel = 'unknown'; uptime_seconds = 0 }
    }

    try {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $load = ($cpus | Measure-Object -Property LoadPercentage -Average).Average
        $inv.cpu = [ordered]@{
            model        = "$($cpus[0].Name)".Trim()
            cores        = [int](($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
            load_percent = if ($null -ne $load) { [int][math]::Round($load) } else { $null }
        }
    }
    catch {
        $inv.errors += "cpu: $($_.Exception.Message)"
    }

    try {
        $inv.disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
            Where-Object { $_.Size -gt 0 } |
            ForEach-Object {
                $used = [double]$_.Size - [double]$_.FreeSpace
                [ordered]@{
                    mount        = $_.DeviceID
                    filesystem   = "$($_.FileSystem)"
                    size_mb      = [int64]($_.Size / 1MB)
                    used_mb      = [int64]($used / 1MB)
                    used_percent = [int][math]::Floor($used * 100 / $_.Size)
                }
            })
    }
    catch {
        $inv.errors += "disks: $($_.Exception.Message)"
    }

    try {
        $interfaces = @(Get-NetAdapter -ErrorAction Stop | Sort-Object -Property Name | ForEach-Object {
                $ips = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                [ordered]@{
                    name  = $_.Name
                    state = "$($_.Status)".ToLower()
                    mac   = ($_.MacAddress -replace '-', ':').ToLower()
                    ipv4  = $ips
                }
            })
        $gateway = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object -Property RouteMetric | Select-Object -First 1 -ExpandProperty NextHop
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
        $inv.network = [ordered]@{
            interfaces = $interfaces
            ipv4_all   = @($interfaces | ForEach-Object { $_.ipv4 } | ForEach-Object { ($_ -split '/')[0] })
            gateway    = "$gateway"
            dns        = $dns
        }
    }
    catch {
        $inv.errors += "network: $($_.Exception.Message)"
        $inv.network = [ordered]@{ interfaces = @(); ipv4_all = @(); gateway = ''; dns = @() }
    }

    try {
        $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object { [int]$_.LocalPort })
        $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.LocalPort })
        $inv.listening_ports = @(
            @($tcp | Sort-Object -Unique | ForEach-Object { "tcp/$_" }) +
            @($udp | Sort-Object -Unique | ForEach-Object { "udp/$_" })
        )
    }
    catch {
        $inv.errors += "ports: $($_.Exception.Message)"
    }

    try {
        $stopped = Get-CimInstance -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction Stop
        $inv.failed_services = @($stopped | Where-Object {
                $name = $_.Name
                -not ($ExcludeService | Where-Object { $name -like $_ })
            } | Sort-Object -Property Name | ForEach-Object { $_.Name })
    }
    catch {
        $inv.errors += "services: $($_.Exception.Message)"
    }

    $inv
}

# --- checks ---------------------------------------------------------------

function Get-ShllLevel {
    param([double]$Value, [double]$Warn, [double]$Crit)
    if ($Value -ge $Crit) { 'CRITICAL' }
    elseif ($Value -ge $Warn) { 'WARNING' }
    else { 'OK' }
}

function Invoke-ShllCheck {
    param(
        [Parameter(Mandatory)] $Inventory,
        [double]$DiskWarn = 80, [double]$DiskCrit = 90,
        [double]$MemWarn = 85, [double]$MemCrit = 95,
        [double]$CpuWarn = 80, [double]$CpuCrit = 95
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $perf = New-Object System.Collections.Generic.List[string]

    foreach ($d in $Inventory.disks) {
        $checks.Add([ordered]@{ name = "disk $($d.mount)"; status = (Get-ShllLevel $d.used_percent $DiskWarn $DiskCrit); message = "$($d.used_percent)% used" })
        $perf.Add("'disk_$($d.mount)'=$($d.used_percent)%;$DiskWarn;$DiskCrit;0;100")
    }

    if ($null -ne $Inventory.memory) {
        $m = $Inventory.memory
        $checks.Add([ordered]@{ name = 'memory'; status = (Get-ShllLevel $m.used_percent $MemWarn $MemCrit); message = "$($m.used_percent)% used ($($m.used_mb)/$($m.total_mb) MB)" })
        $perf.Add("mem=$($m.used_percent)%;$MemWarn;$MemCrit;0;100")
    }
    else {
        $checks.Add([ordered]@{ name = 'memory'; status = 'UNKNOWN'; message = 'memory information unavailable' })
    }

    if ($null -ne $Inventory.cpu -and $null -ne $Inventory.cpu.load_percent) {
        $c = $Inventory.cpu
        $checks.Add([ordered]@{ name = 'cpu'; status = (Get-ShllLevel $c.load_percent $CpuWarn $CpuCrit); message = "$($c.load_percent)% load on $($c.cores) logical core(s)" })
        $perf.Add("cpu=$($c.load_percent)%;$CpuWarn;$CpuCrit;0;100")
    }
    else {
        $checks.Add([ordered]@{ name = 'cpu'; status = 'UNKNOWN'; message = 'cpu load unavailable' })
    }

    if ($null -ne $Inventory.failed_services) {
        $count = @($Inventory.failed_services).Count
        if ($count -eq 0) {
            $checks.Add([ordered]@{ name = 'services'; status = 'OK'; message = 'all automatic services are running' })
        }
        else {
            $checks.Add([ordered]@{ name = 'services'; status = 'WARNING'; message = "$count stopped: $($Inventory.failed_services -join ' ')" })
        }
        $perf.Add("stopped_services=$count;1;;0")
    }

    $overall = 'OK'
    foreach ($c in $checks) {
        switch ($c.status) {
            'CRITICAL' { $overall = 'CRITICAL' }
            'WARNING' { if ($overall -ne 'CRITICAL') { $overall = 'WARNING' } }
            'UNKNOWN' { if ($overall -eq 'OK') { $overall = 'UNKNOWN' } }
        }
    }

    [ordered]@{ status = $overall; checks = [object[]]$checks.ToArray(); perfdata = [string[]]$perf.ToArray() }
}

function Get-ShllExitCode {
    param([string]$Status)
    switch ($Status) { 'OK' { 0 } 'WARNING' { 1 } 'CRITICAL' { 2 } default { 3 } }
}

# --- output ---------------------------------------------------------------

function Format-ShllUptime {
    param([int64]$Seconds)
    $t = [timespan]::FromSeconds($Seconds)
    '{0}d {1}h {2}m' -f [int][math]::Floor($t.TotalDays), $t.Hours, $t.Minutes
}

function ConvertTo-ShllJson {
    param($Inventory, $Result, [string]$Timestamp)
    $doc = [ordered]@{
        tool            = 'sh-ll'
        version         = $ShllVersion
        timestamp       = $Timestamp
        status          = $Result.status
        host            = $Inventory.host
        cpu             = $Inventory.cpu
        memory          = $Inventory.memory
        disks           = @($Inventory.disks)
        network         = $Inventory.network
        listening_ports = @($Inventory.listening_ports)
        failed_services = $Inventory.failed_services
        checks          = @($Result.checks)
        errors          = @($Inventory.errors)
    }
    $doc | ConvertTo-Json -Depth 6
}

function ConvertTo-ShllText {
    param($Inventory, $Result, [string]$Timestamp)
    $sb = New-Object System.Text.StringBuilder
    $h = $Inventory.host
    [void]$sb.AppendLine("SH-LL System Report  $Timestamp").AppendLine()
    [void]$sb.AppendLine('Host')
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'Hostname', $h.hostname))
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'OS', $h.os))
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'Version', $h.kernel))
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'Uptime', (Format-ShllUptime $h.uptime_seconds)))
    [void]$sb.AppendLine().AppendLine('CPU / Memory')
    if ($Inventory.cpu) {
        [void]$sb.AppendLine(('  {0,-12} {1} ({2} logical cores)' -f 'CPU', $Inventory.cpu.model, $Inventory.cpu.cores))
        [void]$sb.AppendLine(('  {0,-12} {1}%' -f 'Load', $Inventory.cpu.load_percent))
    }
    if ($Inventory.memory) {
        $m = $Inventory.memory
        [void]$sb.AppendLine(('  {0,-12} {1} / {2} MB ({3}%)' -f 'Memory', $m.used_mb, $m.total_mb, $m.used_percent))
    }
    [void]$sb.AppendLine().AppendLine('Disks')
    [void]$sb.AppendLine(('  {0,-8} {1,-8} {2,10} {3,10} {4,6}' -f 'Volume', 'FS', 'Size MB', 'Used MB', 'Use%'))
    foreach ($d in $Inventory.disks) {
        [void]$sb.AppendLine(('  {0,-8} {1,-8} {2,10} {3,10} {4,5}%' -f $d.mount, $d.filesystem, $d.size_mb, $d.used_mb, $d.used_percent))
    }
    [void]$sb.AppendLine().AppendLine('Network')
    foreach ($i in $Inventory.network.interfaces) {
        $ips = if (@($i.ipv4).Count) { $i.ipv4 -join ' ' } else { '-' }
        [void]$sb.AppendLine(('  {0,-20} {1,-12} {2,-18} {3}' -f $i.name, $i.state, $i.mac, $ips))
    }
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'Gateway', $(if ($Inventory.network.gateway) { $Inventory.network.gateway } else { '-' })))
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'DNS', $(if (@($Inventory.network.dns).Count) { $Inventory.network.dns -join ' ' } else { '-' })))
    [void]$sb.AppendLine(('  {0,-12} {1}' -f 'Listening', $(if (@($Inventory.listening_ports).Count) { $Inventory.listening_ports -join ' ' } else { '-' })))
    [void]$sb.AppendLine().AppendLine('Checks')
    foreach ($c in $Result.checks) {
        [void]$sb.AppendLine(('  {0,-8} {1,-26} {2}' -f $c.status, $c.name, $c.message))
    }
    foreach ($e in $Inventory.errors) {
        [void]$sb.AppendLine("  ERROR    $e")
    }
    [void]$sb.AppendLine().Append("Overall: $($Result.status)")
    $sb.ToString()
}

function ConvertTo-ShllHtml {
    param($Inventory, $Result, [string]$Timestamp)
    function E([object]$s) { [System.Net.WebUtility]::HtmlEncode("$s") }

    $h = $Inventory.host
    $rows = New-Object System.Text.StringBuilder
    foreach ($c in $Result.checks) {
        [void]$rows.AppendLine("<tr><td><span class=`"badge $($c.status)`">$($c.status)</span></td><td>$(E $c.name)</td><td>$(E $c.message)</td></tr>")
    }
    $disks = New-Object System.Text.StringBuilder
    foreach ($d in $Inventory.disks) {
        [void]$disks.AppendLine("<tr><td>$(E $d.mount)</td><td>$(E $d.filesystem)</td><td>$($d.size_mb)</td><td>$($d.used_mb)</td><td><div class=`"bar`"><span style=`"width:$($d.used_percent)%`"></span></div> $($d.used_percent)%</td></tr>")
    }
    $nets = New-Object System.Text.StringBuilder
    foreach ($i in $Inventory.network.interfaces) {
        [void]$nets.AppendLine("<tr><td>$(E $i.name)</td><td>$(E $i.state)</td><td>$(E $i.mac)</td><td>$(E ($i.ipv4 -join ' '))</td></tr>")
    }
    $cpuText = if ($Inventory.cpu) { "$(E $Inventory.cpu.model) ($($Inventory.cpu.cores) logical cores, $($Inventory.cpu.load_percent)% load)" } else { 'unknown' }
    $memText = if ($Inventory.memory) { "$($Inventory.memory.used_mb) / $($Inventory.memory.total_mb) MB ($($Inventory.memory.used_percent)%)" } else { 'unknown' }

    @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SH-LL Report - $(E $h.hostname)</title>
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
<h1>$(E $h.hostname) <span class="badge $($Result.status)">$($Result.status)</span></h1>
<div class="meta">Generated by sh-ll $ShllVersion at $Timestamp</div>

<h2>Host</h2>
<table>
<tr><th>Operating system</th><td>$(E $h.os)</td></tr>
<tr><th>Version</th><td>$(E $h.kernel)</td></tr>
<tr><th>Uptime</th><td>$(Format-ShllUptime $h.uptime_seconds)</td></tr>
<tr><th>CPU</th><td>$cpuText</td></tr>
<tr><th>Memory</th><td>$memText</td></tr>
</table>

<h2>Checks</h2>
<table>
<tr><th>Status</th><th>Check</th><th>Details</th></tr>
$($rows.ToString())</table>

<h2>Disks</h2>
<table>
<tr><th>Volume</th><th>Filesystem</th><th>Size MB</th><th>Used MB</th><th>Usage</th></tr>
$($disks.ToString())</table>

<h2>Network</h2>
<table>
<tr><th>Interface</th><th>State</th><th>MAC</th><th>IPv4</th></tr>
$($nets.ToString())</table>
<table>
<tr><th>Gateway</th><td>$(E $Inventory.network.gateway)</td></tr>
<tr><th>DNS servers</th><td>$(E ($Inventory.network.dns -join ' '))</td></tr>
<tr><th>Listening ports</th><td>$(E ($Inventory.listening_ports -join ' '))</td></tr>
</table>
</body>
</html>
"@
}

function ConvertTo-ShllQuiet {
    param($Result)
    $crit = @($Result.checks | Where-Object { $_.status -eq 'CRITICAL' }).Count
    $warn = @($Result.checks | Where-Object { $_.status -eq 'WARNING' }).Count
    "SH-LL $($Result.status) - $crit critical, $warn warning, $(@($Result.checks).Count) checks | $($Result.perfdata -join ' ')"
}

# --- main -----------------------------------------------------------------

function Invoke-Shll {
    if ($Version) {
        "sh-ll $ShllVersion"
        $script:ShllExitCode = 0
        return
    }

    # Validated here instead of with ValidateSet/ValidateRange so that bad
    # input exits with 3 (UNKNOWN) like the Linux version.
    if ($Format -notin @('text', 'json', 'html')) {
        [Console]::Error.WriteLine("sh-ll: invalid format: $Format")
        $script:ShllExitCode = 3
        return
    }
    foreach ($t in @('DiskWarn', 'DiskCrit', 'MemWarn', 'MemCrit', 'CpuWarn', 'CpuCrit')) {
        $v = Get-Variable -Name $t -ValueOnly
        if ($v -lt 0 -or $v -gt 100) {
            [Console]::Error.WriteLine("sh-ll: -$t must be between 0 and 100, got $v")
            $script:ShllExitCode = 3
            return
        }
    }

    $pairs = @(
        @('DiskWarn', $DiskWarn, 'DiskCrit', $DiskCrit),
        @('MemWarn', $MemWarn, 'MemCrit', $MemCrit),
        @('CpuWarn', $CpuWarn, 'CpuCrit', $CpuCrit)
    )
    foreach ($p in $pairs) {
        if ($p[1] -gt $p[3]) {
            [Console]::Error.WriteLine("sh-ll: -$($p[0]) must not exceed -$($p[2])")
            $script:ShllExitCode = 3
            return
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        [Console]::Error.WriteLine('sh-ll: this script requires Windows; use linux/sh-ll.sh on Linux')
        $script:ShllExitCode = 3
        return
    }

    $inventory = Get-ShllInventory
    $result = Invoke-ShllCheck -Inventory $inventory -DiskWarn $DiskWarn -DiskCrit $DiskCrit `
        -MemWarn $MemWarn -MemCrit $MemCrit -CpuWarn $CpuWarn -CpuCrit $CpuCrit
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $report = if ($Quiet) { ConvertTo-ShllQuiet -Result $result }
    else {
        switch ($Format) {
            'json' { ConvertTo-ShllJson -Inventory $inventory -Result $result -Timestamp $timestamp }
            'html' { ConvertTo-ShllHtml -Inventory $inventory -Result $result -Timestamp $timestamp }
            default { ConvertTo-ShllText -Inventory $inventory -Result $result -Timestamp $timestamp }
        }
    }

    if ($OutputPath) {
        try {
            [System.IO.File]::WriteAllText($OutputPath, $report + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            [Console]::Error.WriteLine("sh-ll: cannot write to ${OutputPath}: $($_.Exception.Message)")
            $script:ShllExitCode = 3
            return
        }
    }
    else {
        $report
    }

    $script:ShllExitCode = Get-ShllExitCode $result.status
}

# Run only when executed directly; dot-sourcing (used by the tests) just
# loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    $script:ShllExitCode = 3
    Invoke-Shll
    exit $script:ShllExitCode
}
