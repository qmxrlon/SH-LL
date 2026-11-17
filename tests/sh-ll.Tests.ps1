<#
    Tests for windows/sh-ll.ps1.

    The check logic and the renderers are tested with a fixed inventory, so
    this file runs on any platform with PowerShell 5.1 or 7. When run on
    Windows it additionally executes the script against the real machine.

    Usage: pwsh -File tests/sh-ll.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'windows/sh-ll.ps1'
. $target

$script:failed = 0
$script:passed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        Write-Host "ok     $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAILED $Name"
        Write-Host "       $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ("$Expected" -ne "$Actual") { throw "$What : expected '$Expected', got '$Actual'" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestInventory {
    [ordered]@{
        host            = [ordered]@{ hostname = 'WIN-TEST'; platform = 'windows'; os = 'Windows Server 2022 & <Test>'; kernel = '10.0.20348'; uptime_seconds = 93784 }
        cpu             = [ordered]@{ model = 'Test CPU 3000'; cores = 8; load_percent = 12 }
        memory          = [ordered]@{ total_mb = 16000; used_mb = 8000; used_percent = 50 }
        disks           = @(
            [ordered]@{ mount = 'C:'; filesystem = 'NTFS'; size_mb = 100000; used_mb = 42000; used_percent = 42 },
            [ordered]@{ mount = 'D:'; filesystem = 'NTFS'; size_mb = 200000; used_mb = 170000; used_percent = 85 }
        )
        network         = [ordered]@{
            interfaces = @([ordered]@{ name = 'Ethernet'; state = 'up'; mac = '00:11:22:33:44:55'; ipv4 = @('192.168.1.10/24') })
            ipv4_all   = @('192.168.1.10')
            gateway    = '192.168.1.1'
            dns        = @('192.168.1.1', '1.1.1.1')
        }
        listening_ports = @('tcp/135', 'tcp/445', 'udp/123')
        failed_services = @()
        errors          = @()
    }
}

function Get-Status($result, $name) {
    ($result.checks | Where-Object { $_.name -eq $name }).status
}

# --- checks ---------------------------------------------------------------

Test-Case 'level boundaries are inclusive' {
    Assert-Equal 'OK' (Get-ShllLevel 79.9 80 90)
    Assert-Equal 'WARNING' (Get-ShllLevel 80 80 90)
    Assert-Equal 'CRITICAL' (Get-ShllLevel 90 80 90)
}

Test-Case 'disk above warning threshold gives WARNING' {
    $r = Invoke-ShllCheck -Inventory (New-TestInventory)
    Assert-Equal 'WARNING' $r.status 'overall'
    Assert-Equal 'WARNING' (Get-Status $r 'disk D:') 'disk D:'
    Assert-Equal 'OK' (Get-Status $r 'disk C:') 'disk C:'
    Assert-Equal 1 (Get-ShllExitCode $r.status) 'exit code'
}

Test-Case 'disk at critical threshold gives CRITICAL' {
    $r = Invoke-ShllCheck -Inventory (New-TestInventory) -DiskWarn 80 -DiskCrit 85
    Assert-Equal 'CRITICAL' $r.status
    Assert-Equal 2 (Get-ShllExitCode $r.status)
}

Test-Case 'healthy inventory gives OK' {
    $r = Invoke-ShllCheck -Inventory (New-TestInventory) -DiskWarn 90 -DiskCrit 95
    Assert-Equal 'OK' $r.status
    Assert-Equal 0 (Get-ShllExitCode $r.status)
}

Test-Case 'memory and cpu thresholds are evaluated' {
    $r = Invoke-ShllCheck -Inventory (New-TestInventory) -DiskWarn 90 -DiskCrit 95 -MemWarn 40 -MemCrit 60 -CpuWarn 10 -CpuCrit 50
    Assert-Equal 'WARNING' (Get-Status $r 'memory') 'memory'
    Assert-Equal 'WARNING' (Get-Status $r 'cpu') 'cpu'
}

Test-Case 'stopped automatic services give WARNING' {
    $inv = New-TestInventory
    $inv.failed_services = @('Spooler')
    $r = Invoke-ShllCheck -Inventory $inv -DiskWarn 90 -DiskCrit 95
    Assert-Equal 'WARNING' (Get-Status $r 'services')
}

Test-Case 'missing memory and cpu data give UNKNOWN' {
    $inv = New-TestInventory
    $inv.memory = $null
    $inv.cpu = $null
    $r = Invoke-ShllCheck -Inventory $inv -DiskWarn 90 -DiskCrit 95
    Assert-Equal 'UNKNOWN' $r.status
    Assert-Equal 3 (Get-ShllExitCode $r.status)
}

Test-Case 'CRITICAL outranks UNKNOWN' {
    $inv = New-TestInventory
    $inv.memory = $null
    $r = Invoke-ShllCheck -Inventory $inv -DiskWarn 80 -DiskCrit 85
    Assert-Equal 'CRITICAL' $r.status
}

# --- renderers ------------------------------------------------------------

Test-Case 'json output has the shared schema' {
    $inv = New-TestInventory
    $r = Invoke-ShllCheck -Inventory $inv
    $doc = ConvertTo-ShllJson -Inventory $inv -Result $r -Timestamp '2026-01-01T00:00:00Z' | ConvertFrom-Json
    Assert-Equal 'sh-ll' $doc.tool
    Assert-Equal 'WARNING' $doc.status
    Assert-Equal 'WIN-TEST' $doc.host.hostname
    Assert-Equal 2 @($doc.disks).Count 'disk count'
    Assert-Equal '192.168.1.1' $doc.network.gateway
    Assert-Equal 'tcp/135 tcp/445 udp/123' ($doc.listening_ports -join ' ')
    Assert-Equal 5 @($doc.checks).Count 'check count'
}

Test-Case 'quiet output is one line with perfdata' {
    $r = Invoke-ShllCheck -Inventory (New-TestInventory)
    $line = ConvertTo-ShllQuiet -Result $r
    Assert-True ($line -like 'SH-LL WARNING - 0 critical, 1 warning, 5 checks | *') "unexpected line: $line"
    Assert-True ($line -like "*'disk_C:'=42%;80;90;0;100*") "missing disk perfdata: $line"
    Assert-True ($line -like '*mem=50%;85;95;0;100*') "missing memory perfdata: $line"
}

Test-Case 'text output lists all sections' {
    $inv = New-TestInventory
    $r = Invoke-ShllCheck -Inventory $inv
    $text = ConvertTo-ShllText -Inventory $inv -Result $r -Timestamp 'now'
    foreach ($s in 'SH-LL System Report', 'WIN-TEST', 'Disks', 'Network', 'Checks', 'Overall: WARNING', '1d 2h 3m') {
        Assert-True ($text.Contains($s)) "missing '$s'"
    }
}

Test-Case 'html output escapes content' {
    $inv = New-TestInventory
    $r = Invoke-ShllCheck -Inventory $inv
    $html = ConvertTo-ShllHtml -Inventory $inv -Result $r -Timestamp 'now'
    Assert-True ($html.StartsWith('<!DOCTYPE html>')) 'no doctype'
    Assert-True ($html.Contains('Windows Server 2022 &amp; &lt;Test&gt;')) 'os name not escaped'
    Assert-True (-not $html.Contains('<Test>')) 'raw markup leaked'
}

# --- end to end (Windows only) --------------------------------------------

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$shell = (Get-Process -Id $PID).Path

if ($onWindows) {
    Test-Case 'real run produces valid json and a Nagios exit code' {
        $json = & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target -Format json
        $code = $LASTEXITCODE
        Assert-True ($code -in 0, 1, 2, 3) "unexpected exit code $code"
        $doc = ($json -join "`n") | ConvertFrom-Json
        Assert-Equal 'windows' $doc.host.platform
        Assert-True (@($doc.disks).Count -ge 1) 'no disks found'
        Assert-True ($doc.memory.total_mb -gt 0) 'no memory data'
        Assert-Equal 0 @($doc.errors).Count "collection errors: $($doc.errors -join '; ')"
    }

    Test-Case 'real run writes an html report' {
        $out = Join-Path ([IO.Path]::GetTempPath()) 'sh-ll-test.html'
        & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target -Format html -OutputPath $out | Out-Null
        Assert-True (Test-Path $out) 'report not written'
        Assert-True ((Get-Content $out -Raw).Contains('<!DOCTYPE html>')) 'not html'
        Remove-Item $out
    }
}
else {
    Test-Case 'refuses to run on non-Windows with exit 3' {
        & $shell -NoLogo -NoProfile -File $target 2>$null | Out-Null
        Assert-Equal 3 $LASTEXITCODE
    }
}

Test-Case 'invalid arguments exit 3' {
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target -Format xml 2>$null | Out-Null
    Assert-Equal 3 $LASTEXITCODE 'invalid format'
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target -MemWarn 90 -MemCrit 80 2>$null | Out-Null
    Assert-Equal 3 $LASTEXITCODE 'warn above crit'
}

Write-Host ''
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
