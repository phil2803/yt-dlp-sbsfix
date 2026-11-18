# SBS / ABC iView / BBC iPlayer downloader (Windows)

A small set of PowerShell scripts around the **official [yt-dlp](https://github.com/yt-dlp/yt-dlp)**
that download full episodes (with English subtitles) from **SBS On Demand**, **ABC iView**,
**BBC iPlayer** and **YouTube** into `.mkv` files, sorted into per-show folders.

It also includes **`sbsfix`, a yt-dlp plugin that makes SBS On Demand work again** on the
official yt-dlp release.

## Why the SBS plugin?

SBS switched off the old public SMIL API, so stock yt-dlp fails on every SBS video with
`Unable to download SMIL file: HTTP Error 410: Gone`
([yt-dlp#16529](https://github.com/yt-dlp/yt-dlp/issues/16529)).

**The fix is by [@0xvd](https://github.com/0xvd)** in
[yt-dlp PR #16543](https://github.com/yt-dlp/yt-dlp/pull/16543) (`[ie/sbs] Fix extractor`),
which uses SBS's logged-in playback API. Until that PR is merged, the usual workaround is to
run 0xvd's fork or a self-built exe.

`sbsfix` packages the same extractor code (from 0xvd's `fix_sbs` branch) as a
[yt-dlp plugin](https://github.com/yt-dlp/yt-dlp#plugins) that overrides the built-in SBS
extractor. That means you can:

- keep using the **official** `yt-dlp.exe`,
- update it normally with `yt-dlp -U` (the plugin lives outside the exe and survives updates),
- delete the plugin folder once PR #16543 lands upstream.

All credit for the extractor goes to 0xvd. This repo only repackages it.

### Update 19 Nov 2026: "DRM is required for this stream"

On 18 Nov 2026 SBS changed its playback API, and every video started failing with
"This video is only available for registered users" (the API itself says
`DRM is required for this stream, but no DRM was requested`). The plugin now uses the fix
posted on the Whirlpool SBS forum and shared in
[PR #16543](https://github.com/yt-dlp/yt-dlp/pull/16543#issuecomment-6994440135).
The request lists SBS's DRM stream types, and SBS then also returns its plain `AES_HLS`
stream. The plugin downloads only that unprotected stream and skips anything with DRM.
If you downloaded the plugin before 19 Nov, replace `sbsfix.py` with the current one.

### Using just the plugin

You don't need the scripts to use the plugin. Copy the `yt-dlp-plugins` folder next to your
`yt-dlp.exe` (or into any
[plugin location](https://github.com/yt-dlp/yt-dlp#installing-plugins)):

```
yt-dlp.exe
yt-dlp-plugins\
    sbsfix\
        yt_dlp_plugins\
            extractor\
                sbsfix.py
```

Check it loaded:

```
yt-dlp -v --simulate https://www.sbs.com.au/ondemand
...
[debug] Extractor Plugins: sbsfix (SBSIE)
```

SBS now requires a (free) SBS On Demand account, so pass `-u EMAIL -p PASSWORD`
(or use `--netrc` with machine `sbs`). Cookies are not supported.

> Plugins work with the official Windows `yt-dlp.exe` and with pip installs.

## The scripts

| File | What it does |
|------|--------------|
| `download_sbs.ps1` | Main downloader. Works through `sbs_queue.txt` (SBS / iView / YouTube), skips anything already in `downloaded.txt`, retries failures, sorts output into show folders. Drops any WireGuard tunnel first, since SBS/iView are Australia-only. |
| `download_bbc.ps1` | BBC downloader. Brings up a UK WireGuard tunnel, **checks you really are on a UK IP**, runs `bbc_queue.txt`, then drops the tunnel. |
| `scrape_sbs.ps1` | Expands a series/show page into individual episode URLs and appends them to the right queue. Handles SBS series pages (yt-dlp can't), every season of an iView show (via ABC's API), and BBC `/episodes/` pages. |
| `menu.bat` | Optional one-key menu for all of the above. |
| `yt-dlp-plugins\sbsfix` | The SBS fix plugin (see above). |

### Setup

1. Download this repo into a folder.
2. Put these in the same folder (they aren't included here):
   - [`yt-dlp.exe`](https://github.com/yt-dlp/yt-dlp/releases/latest)
   - `ffmpeg.exe` and `ffprobe.exe` (for example from
     [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds/releases))
   - `deno.exe` (only for YouTube): [denoland/deno releases](https://github.com/denoland/deno/releases)
3. **SBS only:** open `download_sbs.ps1` and fill in your SBS On Demand login near the top:
   ```powershell
   $sbsUser = "YOUR_SBS_EMAIL"
   $sbsPass = "YOUR_SBS_PASSWORD"
   ```
4. Copy `sbs_queue.example.txt` to `sbs_queue.txt` and `bbc_queue.example.txt` to
   `bbc_queue.txt`, then set your output folders in the first lines.
5. **BBC only:** install [WireGuard](https://www.wireguard.com/install/), get a UK server
   `.conf` from your VPN provider's manual-setup page, and set its path in `download_bbc.ps1`:
   ```powershell
   [string]$Conf = "C:\vpn\uk-london.conf"
   ```

### Use

1. Add URLs to `sbs_queue.txt` (one per line), or run `scrape_sbs.ps1` and paste a
   series/show URL to have the episodes added for you.
2. Run `download_sbs.ps1` (AU sources) or `download_bbc.ps1` (BBC; asks for admin once
   because WireGuard needs it).

Or just run `menu.bat`.

If Windows says "running scripts is disabled", run them as
`powershell -ExecutionPolicy Bypass -File download_sbs.ps1`.

### Queue file options

```
sbstv     = D:\video\sbs\tv        # base folders (first lines of the queue)
sbsmovies = D:\video\sbs\movies
iview     = D:\video\iview
youtube   = D:\video\youtube
default   = D:\video\misc
bbc       = D:\video\bbc           # (in bbc_queue.txt)

DEST=E:\somewhere\else             # manual destination for the lines that follow
DEST=AUTO                          # back to auto-routing
# comment lines are ignored
```

### Notes and gotchas

- **Geography:** SBS and iView are Australia-only and BBC iPlayer is UK-only. Keep BBC in its own
  queue and never mix them in one run.
- **SBS series pages** can't be downloaded directly. Use `scrape_sbs.ps1` or paste episode URLs
  (the ones ending in a number).
- **iView:** `/show/<name>` alone downloads only the latest season. Use the scraper for all
  seasons, or `/show/<name>/series/2` for a specific one.
- **BBC:** a wall of "Downloading MPD manifest" lines and a few m3u8 403 warnings are normal.
- YouTube is capped at 1080p.
- DRM services (Netflix, Stan, Disney+, Prime) won't work.
- Re-running is safe. To force a re-download, remove the item's line from `downloaded.txt`.

Only download content you're entitled to watch, and respect each service's terms.

## Licence

[Unlicense](LICENSE) (public domain), the same as yt-dlp.
