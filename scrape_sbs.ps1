# scrape_sbs.ps1
# Expand an SBS / ABC iView / BBC iPlayer series page into individual episode
# URLs and auto-append them to the right queue: BBC URLs go to bbc_queue.txt
# (needs a UK VPN, run via download_bbc.ps1), everything else to sbs_queue.txt.
#
#   SBS  : yt-dlp cannot enumerate SBS series landing pages, so we scrape the
#          episode links straight out of the page HTML.
#   iView: episode lists come from ABC's JSON API (yt-dlp's show extractor broke).
#   BBC  : yt-dlp enumerates /iplayer/episodes/<id> natively.
#   YouTube: queued as-is.

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$queueFile    = Join-Path $scriptDir "sbs_queue.txt"
$bbcQueueFile = Join-Path $scriptDir "bbc_queue.txt"
$ytdlp        = Join-Path $scriptDir "yt-dlp.exe"

if (-not (Test-Path $ytdlp)) {
    Write-Host "ERROR: yt-dlp.exe not found in $scriptDir"
    Read-Host "Press Enter to close"; exit 1
}

$sbsUrls = [System.Collections.Generic.List[string]]::new()
$bbcUrls = [System.Collections.Generic.List[string]]::new()

while ($true) {
    $url = Read-Host "`nEnter an SBS, iView, BBC or YouTube URL (or press Enter to finish)"
    $url = $url.Trim()
    if ($url -eq "") { break }

    $urls  = $null
    $isBbc = $false

    if ($url -match "sbs\.com\.au") {
        # SBS: scrape episode links (each ends in a numeric ID) from the HTML.
        Write-Host "Scraping SBS page: $url"
        try {
            $html = (Invoke-WebRequest $url -UseBasicParsing -ErrorAction Stop).Content
        } catch {
            Write-Host "ERROR: Could not fetch page - $_"; continue
        }
        $m = [regex]::Matches($html, '/ondemand/(?:watch|tv-series|movie)/[^"'']*?/\d{6,}')
        $urls = $m | ForEach-Object { "https://www.sbs.com.au" + $_.Value } | Select-Object -Unique
    }
    elseif ($url -match "iview\.abc\.net\.au") {
        # iView: enumerate via ABC's own JSON API. (yt-dlp's iView show/series
        # extractor broke in Oct 2026 - "Unable to extract initial state" on every
        # show - but it still downloads single /video/ episodes fine.)
        #   /show/<name>               -> every season listed by the API
        #   /show/<name>/series/<N>    -> just that season
        #   anything with /video/<id>  -> queued as-is
        # Episode URLs use the /show/<name>/series/<N>/video/<id> deeplink form so
        # download_sbs.ps1 still routes them to iview\<Show Name>.
        $api = "https://api.iview.abc.net.au/v3"
        $url = $url -replace '[?#].*$', '' -replace '/series/?$', '' -replace '/$', ''
        $collected = [System.Collections.Generic.List[string]]::new()
        if ($url -match "/video/[A-Za-z0-9]+$") {
            $collected.Add($url)
        } elseif ($url -match "iview\.abc\.net\.au/show/([^/]+)(?:/series/([^/]+))?$") {
            $slug = $matches[1]
            $seasonPaths = @()
            if ($matches[2]) {
                $seasonPaths = @("/series/$slug/$($matches[2])")
                Write-Host "Expanding iView season: $slug series $($matches[2])"
            } else {
                Write-Host "Expanding iView show (all seasons): $slug"
                try {
                    $show = Invoke-RestMethod "$api/show/$slug" -ErrorAction Stop
                    $seasonPaths = @($show._embedded.seriesList | ForEach-Object { $_._links.self.href })
                } catch {
                    Write-Host "ERROR: iView API lookup failed for '$slug' - $_"; continue
                }
            }
            foreach ($sp in $seasonPaths) {
                try {
                    $season = Invoke-RestMethod "$api$sp" -ErrorAction Stop
                } catch {
                    Write-Host "  $sp : could not fetch - $_"; continue
                }
                $eps = $season._embedded.videoEpisodes
                if ($eps.items) { $eps = $eps.items }
                # API lists newest first; reverse so the queue runs Ep 1 upwards.
                $epUrls = @($eps | ForEach-Object { "https://iview.abc.net.au" + $_._links.deeplink.href })
                [array]::Reverse($epUrls)
                Write-Host "  $($season.displaySubtitle): $($epUrls.Count) episode(s)"
                $epUrls | ForEach-Object { $collected.Add($_) }
            }
        } else {
            Write-Host "Unrecognised iView URL (expected /show/<name>...): $url"; continue
        }
        $urls = $collected | Select-Object -Unique
    }
    elseif ($url -match "bbc\.co\.uk") {
        $isBbc = $true
        # BBC iPlayer: yt-dlp enumerates an /episodes/<id> series page natively
        # (and a single /episode/<id> just returns itself), so let it do the work.
        # NOTE: actual download needs a UK IP - extraction works from anywhere but
        # the media manifests are geo-locked.
        Write-Host "Expanding BBC iPlayer: $url"
        $collected = [System.Collections.Generic.List[string]]::new()
        $out = & $ytdlp --flat-playlist --no-warnings --print "%(url)s" $url 2>&1
        $out | ForEach-Object { "$_" } | Where-Object { $_ -match '^https?://' } | ForEach-Object { $collected.Add($_) }
        $urls = $collected | Select-Object -Unique
    }
    elseif ($url -match "youtube\.com|youtu\.be") {
        # YouTube: nothing to expand - queue as-is (yt-dlp handles videos and
        # playlists itself; download_sbs.ps1 routes it to the youtube folder).
        $urls = @($url)
    }
    else {
        Write-Host "Not an SBS, iView, BBC or YouTube URL - skipping."; continue
    }

    if (-not $urls -or @($urls).Count -eq 0) {
        Write-Host "No episodes found (check the URL, or the page may need login)."
        continue
    }

    # Assign the list reference directly. Do NOT use `$target = if (...) {...}`:
    # an `if` used as an expression writes its branch to the output stream, and
    # because these are List[string] (enumerable) an EMPTY list unrolls to
    # nothing, leaving $target = $null (the "call a method on null" error).
    if ($isBbc) { $target = $bbcUrls } else { $target = $sbsUrls }
    Write-Host "Found $(@($urls).Count) episode(s):"
    $urls | ForEach-Object { Write-Host "  $_"; $target.Add($_) }
}

# Nothing entered / collected: just close, no prompt.
if ($sbsUrls.Count -eq 0 -and $bbcUrls.Count -eq 0) { exit }

# Auto-append each list to its queue (no confirmation).
if ($sbsUrls.Count -gt 0) {
    Add-Content $queueFile ("`n" + ($sbsUrls -join "`n"))
    Write-Host "`nAppended $($sbsUrls.Count) URL(s) to sbs_queue.txt  (run download_sbs.ps1)"
}
if ($bbcUrls.Count -gt 0) {
    Add-Content $bbcQueueFile ("`n" + ($bbcUrls -join "`n"))
    Write-Host "`nAppended $($bbcUrls.Count) URL(s) to bbc_queue.txt  (run download_bbc.ps1 - needs UK VPN)"
}

Read-Host "Press Enter to close"
