# download_bbc.ps1
# Hands-off BBC iPlayer downloader. BBC is UK geo-locked, so this brings up the
# UK WireGuard tunnel, runs the BBC-only queue, then drops the tunnel again.
# The AU sources (SBS/iView/YouTube) stay in sbs_queue.txt / download_sbs.ps1.
#
# WireGuard service control needs admin, so this self-elevates (one UAC prompt).
# If the tunnel is ALREADY up (e.g. you activated it in the WireGuard app), it
# just uses it and leaves it up afterwards.

param(
    [string]$Conf  = "C:\vpn\uk-london.conf",   # <-- your UK WireGuard config
    [string]$Queue = "bbc_queue.txt"
)

$ErrorActionPreference = "Stop"

# --- Self-elevate -------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as administrator (WireGuard needs admin)..."
    $relaunch = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Conf `"$Conf`" -Queue `"$Queue`""
    Start-Process powershell -Verb RunAs -ArgumentList $relaunch
    exit
}

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$wg         = "C:\Program Files\WireGuard\wireguard.exe"
$tunnel     = [System.IO.Path]::GetFileNameWithoutExtension($Conf)   # e.g. uk-london
$downloader = Join-Path $scriptDir "download_sbs.ps1"

function Get-ExitInfo {
    try { return Invoke-RestMethod "http://ip-api.com/json/?fields=countryCode,country,city,query" -TimeoutSec 6 }
    catch { return $null }
}
function Tunnel-IsUp {
    $a = Get-NetAdapter -Name $tunnel -ErrorAction SilentlyContinue
    return ($a -and $a.Status -eq 'Up')
}

# --- Sanity checks ------------------------------------------------------------
if (-not (Test-Path $wg))         { Write-Host "ERROR: wireguard.exe not found at $wg"; Read-Host "Press Enter to close"; exit 1 }
if (-not (Test-Path $Conf))       { Write-Host "ERROR: WireGuard config not found: $Conf"; Read-Host "Press Enter to close"; exit 1 }
if (-not (Test-Path $downloader)) { Write-Host "ERROR: download_sbs.ps1 not found in $scriptDir"; Read-Host "Press Enter to close"; exit 1 }

$broughtUp = $false
try {
    if (Tunnel-IsUp) {
        Write-Host "Tunnel '$tunnel' is already up - using it (will leave it up afterwards)."
    } else {
        Write-Host "Bringing up WireGuard tunnel '$tunnel'..."
        & $wg /installtunnelservice $Conf
        for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (Tunnel-IsUp) { break } }
        if (-not (Tunnel-IsUp)) { Write-Host "ERROR: tunnel did not come up."; Read-Host "Press Enter to close"; exit 1 }
        $broughtUp = $true
    }

    # Verify we are actually exiting via the UK BEFORE downloading, so BBC does
    # not 403 and files are not grabbed through the wrong country.
    Write-Host "Checking exit location..."
    $ok = $false
    for ($i = 0; $i -lt 10; $i++) {
        $info = Get-ExitInfo
        if ($info -and $info.countryCode -eq 'GB') {
            Write-Host "Exit OK: $($info.city), $($info.country) ($($info.query))"
            $ok = $true; break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ok) {
        Write-Host "ERROR: not exiting via the UK - aborting (BBC would 403)."
        Read-Host "Press Enter to close"; exit 1
    }

    Write-Host "`nRunning BBC queue: $Queue`n"
    & $downloader -Queue $Queue -BbcRun
}
finally {
    if ($broughtUp) {
        Write-Host "`nDropping WireGuard tunnel '$tunnel'..."
        & $wg /uninstalltunnelservice $tunnel
    } else {
        Write-Host "`nLeaving tunnel up (it was already running when this started)."
    }
}

Write-Host "`nDone."
Read-Host "Press Enter to close"
