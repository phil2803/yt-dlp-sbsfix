# --- Default base paths for auto-routing --------------------------------------
# These are defaults. You can override any of them at the top of sbs_queue.txt:
#   sbstv     = d:\video\sbs\tv
#   sbsmovies = d:\video\movies
#   iview     = d:\video\iview
#   bbc       = d:\video\bbc
#   youtube   = d:\video\youtube
#   default   = d:\video\misc
# ------------------------------------------------------------------------------
# -Queue lets you point at a different queue file (default sbs_queue.txt).
# BBC content needs a UK VPN, so it lives in its own bbc_queue.txt and is run
# via download_bbc.ps1; the AU sources (SBS/iView) stay in sbs_queue.txt.
param([string]$Queue, [switch]$BbcRun)

$sbsTvBase    = "D:\video\sbs\tv"
$sbsMovieBase = "D:\video\sbs\movies"
$iviewBase    = "D:\video\iview"
$bbcBase      = "D:\video\bbc"
$youtubeBase  = "D:\video\youtube"
$defaultBase  = "D:\video\misc"

# --- SBS login (only needed for SBS On Demand; iView/BBC/YouTube need none) ----
$sbsUser = "YOUR_SBS_EMAIL"
$sbsPass = "YOUR_SBS_PASSWORD"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Queue) {
    $queueFile = if ([System.IO.Path]::IsPathRooted($Queue)) { $Queue } else { Join-Path $scriptDir $Queue }
} else {
    $queueFile = Join-Path $scriptDir "sbs_queue.txt"
}
$ytdlp     = Join-Path $scriptDir "yt-dlp.exe"
$archive   = "$scriptDir\downloaded.txt"
$dest      = $null   # $null = auto-detect per URL
$maxRetries = 3
# YouTube's JS challenge is solved automatically by deno.exe sitting in this
# folder (yt-dlp auto-detects and enables Deno). Without it, some YouTube
# formats go missing and yt-dlp warns that the no-runtime path is deprecated.

function Get-AutoDest($url) {
    # SBS TV series: /ondemand/tv-series/show-name/...
    if ($url -match "sbs\.com\.au/ondemand/tv-series/([^/?]+)") {
        $show = (Get-Culture).TextInfo.ToTitleCase($matches[1].Replace('-', ' '))
        return "$sbsTvBase\$show"
    }
    # Any other SBS URL -> movies folder
    if ($url -match "sbs\.com\.au") { return $sbsMovieBase }

    # iView show: /show/show-name/...
    if ($url -match "iview\.abc\.net\.au/show/([^/?]+)") {
        $show = (Get-Culture).TextInfo.ToTitleCase($matches[1].Replace('-', ' '))
        return "$iviewBase\$show"
    }
    if ($url -match "iview\.abc\.net\.au") { return $iviewBase }

    # BBC iPlayer: scraped episode URLs are bare PIDs with no show name, so route
    # all of them to the BBC base; the per-show subfolder is added via the
    # %(series)s output template at download time (see below).
    if ($url -match "bbc\.co\.uk") { return $bbcBase }

    if ($url -match "youtube\.com|youtu\.be") { return $youtubeBase }

    return $defaultBase
}

function Ensure-Dir($path) {
    if ($path -notmatch '^[a-zA-Z]:\\') {
        Write-Host "ERROR: DEST must be a full path e.g. D:\video\sbs\movies - got: $path"; exit 1
    }
    if ($path -match '[*?"|<>]') {
        Write-Host "ERROR: Invalid characters in path: $path"; exit 1
    }
    $drive = $path.Substring(0, 3)
    if (-not (Test-Path $drive)) {
        Write-Host "ERROR: Drive not found: $drive"; exit 1
    }
    try {
        if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null }
    } catch {
        Write-Host "ERROR: Could not create folder $path - $_"; exit 1
    }
}

# --- Post-download: group loose files into per-show subfolders ------------------
# Sources like BBC (and anything routed to misc) deliver episodes named
#   "Show Name, Series 1, Episode 3"  /  "Show Name, Episode 3"
# straight into the base folder. This folds each loose video (plus any sidecar
# sharing its exact stem, e.g. .en.srt) into a "Show Name" subfolder. A file with
# no Series/Episode marker is treated as a one-off film and moved to a "movies"
# subfolder - except obvious junk remux artifacts, which are left in place.
# Only loose files in the base root are touched; existing subfolders are never
# recursed into, so already-foldered content (sbs\tv, prior bbc shows) is safe.
function Sort-IntoShowFolders {
    param([string]$Base, [switch]$WhatIf)
    if (-not (Test-Path -LiteralPath $Base)) { return }
    $vids = Get-ChildItem -LiteralPath $Base -File |
            Where-Object { $_.Extension -ieq '.mkv' -or $_.Extension -ieq '.mp4' }
    if (-not $vids) { return }
    foreach ($v in $vids) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($v.Name)
        if ($stem -match '^(.*?),\s*(?:Series|Episode)\s+\d+') {
            $folder = $matches[1].Trim()
        } else {
            # No Series/Episode marker -> one-off film, unless it is a junk artifact
            if ($v.Name -match '=|\.ism\.|hlsv2') { continue }
            $folder = 'movies'
        }
        $target = Join-Path $Base $folder
        # Move the video plus any sidecar that shares its exact stem (literal '.'
        # boundary so "Ep 1" never grabs "Ep 10"); StartsWith avoids -like globbing.
        $mates = Get-ChildItem -LiteralPath $Base -File |
                 Where-Object { $_.Name.StartsWith($stem + '.', [System.StringComparison]::OrdinalIgnoreCase) }
        foreach ($m in $mates) {
            if ($WhatIf) { Write-Host "WOULD MOVE: $($m.Name)  ->  $folder\"; continue }
            if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
            if (Test-Path -LiteralPath (Join-Path $target $m.Name)) {
                Write-Host "SKIP (exists): $folder\$($m.Name)"
            } else {
                Move-Item -LiteralPath $m.FullName -Destination $target
                Write-Host "Sorted: $($m.Name)  ->  $folder\"
            }
        }
    }
}

# --- Ensure the UK VPN is OFF for AU downloads --------------------------------
# SBS / iView / YouTube are AU (or AU-geo) sources; a live UK WireGuard tunnel
# makes SBS/iView geo-block or hand back the wrong catalogue. A direct AU run
# (menu option 2) therefore drops any active WireGuard tunnel first. The BBC
# path passes -BbcRun so the UK tunnel it just raised is left alone.
# Dropping a tunnel needs admin, so this elevates a one-shot - but ONLY when a
# tunnel is actually up, so a normal AU run with no VPN sees no UAC prompt.
function Get-LiveWgTunnels {
    try {
        return @(Get-NetAdapter -ErrorAction Stop |
                 Where-Object { $_.InterfaceDescription -like 'WireGuard Tunnel*' -and $_.Status -eq 'Up' })
    } catch { return @() }
}
function Ensure-VpnOff {
    $wg = "C:\Program Files\WireGuard\wireguard.exe"
    $up = Get-LiveWgTunnels
    if (-not $up) { return }
    $names = @($up.Name)
    if (-not (Test-Path $wg)) {
        Write-Host "WARNING: VPN tunnel up ($($names -join ', ')) but wireguard.exe not found - cannot drop it."
        Write-Host "         SBS/iView may geo-block; turn the VPN off manually."
        return
    }
    Write-Host "VPN tunnel up ($($names -join ', ')) - dropping for AU download..."
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        # Already elevated (e.g. launched from an admin prompt) - drop in-process, no UAC.
        foreach ($n in $names) { & $wg /uninstalltunnelservice $n }
    } else {
        $drop = ($names | ForEach-Object { "& '$wg' /uninstalltunnelservice '$_'" }) -join '; '
        Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$drop`""
    }
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Get-LiveWgTunnels)) { Write-Host "VPN is off."; return }
    }
    Write-Host "WARNING: VPN tunnel still appears up after 15s; SBS/iView may geo-block."
}

if (-not $BbcRun) { Ensure-VpnOff }

if (-not (Test-Path $ytdlp))     { Write-Host "ERROR: yt-dlp.exe not found in $scriptDir"; Read-Host "Press Enter to close"; exit 1 }
if (-not (Test-Path $queueFile)) { Write-Host "ERROR: sbs_queue.txt not found in $scriptDir"; Read-Host "Press Enter to close"; exit 1 }

$downloaded = [System.Collections.Generic.HashSet[string]]::new()
if (Test-Path $archive) {
    Get-Content $archive | ForEach-Object { [void]$downloaded.Add($_.Trim()) }
}

foreach ($line in Get-Content $queueFile) {
    $line = $line.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { continue }

    # Base-path config lines, e.g.  sbstv = d:\video\sbs\tv
    if ($line -match "^(sbstv|sbsmovies|iview|bbc|youtube|default)\s*=\s*(.+)$") {
        $key = $matches[1].ToLower()
        $val = $matches[2].Trim().TrimEnd('\', '/')
        switch ($key) {
            "sbstv"     { $sbsTvBase    = $val }
            "sbsmovies" { $sbsMovieBase = $val }
            "iview"     { $iviewBase    = $val }
            "bbc"       { $bbcBase      = $val }
            "youtube"   { $youtubeBase  = $val }
            "default"   { $defaultBase  = $val }
        }
        Write-Host "Base path set: $key -> $val"
        continue
    }

    # DEST= / DEST: sets a manual override for the lines that follow.
    # Use DEST=AUTO to go back to auto-detection.
    if ($line -match "^DEST[=:](.*)$") {
        $val = $matches[1].Trim().TrimEnd('\', '/')
        if ($val -eq "" -or $val -ieq "AUTO") {
            $dest = $null
            Write-Host "Destination: auto-detect"
        } else {
            $dest = $val
            Ensure-Dir $dest
            Write-Host "Output folder (manual): $dest"
        }
        continue
    }

    # Resolve destination: manual override or auto-detect from URL
    $effectiveDest = if ($dest) { $dest } else { Get-AutoDest $line }
    Ensure-Dir $effectiveDest

    # Skip check against archive
    if ($line -match "sbs\.com\.au/.*?/(\d+)(?:\?|$)") {
        $id = "sbs $($matches[1])"
        if ($downloaded.Contains($id)) { Write-Host "Skipping (already downloaded): $line"; continue }
    } elseif ($line -match "iview\.abc\.net\.au/(?:video|show/.+?)/([A-Z0-9]+)(?:\?|$)") {
        $id = "abciview $($matches[1])"
        if ($downloaded.Contains($id)) { Write-Host "Skipping (already downloaded): $line"; continue }
    }

    $isSBS = $line -match "sbs\.com\.au"
    $isBBC = $line -match "bbc\.co\.uk"
    # YouTube: cap at 1080p (4K is ~5x the size). YouTube serves each format as
    # one whole file, so --concurrent-fragments does nothing there - but a single
    # connection already runs ~50 MB/s. aria2c multi-connection was tried
    # 2026-10-14: YouTube answers 403, so don't bother.
    $ytArgs = @()
    if ($line -match "youtube\.com|youtu\.be") {
        $ytArgs = @('-f', 'bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b')
    }
    # BBC episode URLs carry no show name, so group by series via metadata.
    # %(series|)s falls back to empty (not "NA") when a show has no series field.
    if ($isBBC) { $outTmpl = "$effectiveDest\%(series|)s\%(title)s.%(ext)s" }
    else        { $outTmpl = "$effectiveDest\%(title)s.%(ext)s" }
    Write-Host "`nDownloading: $line"
    Write-Host "         -> $effectiveDest"

    $attempt = 0
    $success = $false
    while (-not $success -and $attempt -lt $maxRetries) {
        $attempt++
        if ($attempt -gt 1) { Write-Host "Retry $($attempt - 1) of $($maxRetries - 1)..." }
        if ($isSBS) {
            & $ytdlp -u $sbsUser -p $sbsPass `
                --download-archive $archive `
                --write-subs --sub-langs en --convert-subs srt `
                --merge-output-format mkv --remux-video mkv `
                --concurrent-fragments 8 --retries 5 --fragment-retries 5 `
                --replace-in-metadata "title,series" "\s*:\s*" " - " `
                -o "$outTmpl" $line
        } else {
            & $ytdlp @ytArgs `
                --download-archive $archive `
                --write-subs --sub-langs en --convert-subs srt `
                --merge-output-format mkv --remux-video mkv `
                --concurrent-fragments 8 --retries 5 --fragment-retries 5 `
                --replace-in-metadata "title,series" "\s*:\s*" " - " `
                -o "$outTmpl" $line
        }
        if ($LASTEXITCODE -eq 0) { $success = $true }
        elseif ($attempt -lt $maxRetries) { Start-Sleep -Seconds 5 }
    }
    if (-not $success) { Write-Host "FAILED after $maxRetries attempts: $line" }
}

# Tidy loose downloads into per-show subfolders (BBC + iView + misc; sbs\tv is
# already foldered by slug, sbs\movies is intentionally flat, youtube is left
# alone since its titles are not "Show, Series N" shaped).
Write-Host "`nSorting loose files into show folders..."
Sort-IntoShowFolders -Base $bbcBase
Sort-IntoShowFolders -Base $iviewBase
Sort-IntoShowFolders -Base $defaultBase

Write-Host "`nAll done."
Read-Host "Press Enter to close"
