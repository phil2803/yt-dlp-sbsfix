@echo off
rem menu.bat - one-key launcher for the SBS / iView / BBC downloader.
setlocal
cd /d "%~dp0"

:menu
cls
echo.
echo    SBS / ABC iView / BBC iPlayer downloader
echo    =======================================
echo.
echo    [1]  Scrape a series page into a queue      (scrape_sbs.ps1)
echo.
echo    [2]  Download AU queue - SBS/iView/YouTube  (download_sbs.ps1)
echo    [3]  Download BBC queue - brings up UK VPN   (download_bbc.ps1)
echo.
echo    [4]  Edit  sbs_queue.txt   (AU sources)
echo    [5]  Edit  bbc_queue.txt   (BBC, UK only)
echo    [6]  View  downloaded.txt  (archive of finished items)
echo.
echo    [Q]  Quit
echo.
choice /c 123456Q /n /m "Choose: "
set c=%errorlevel%
echo.

if %c%==1 powershell -ExecutionPolicy Bypass -File "scrape_sbs.ps1"
if %c%==2 (powershell -ExecutionPolicy Bypass -File "download_sbs.ps1" & echo. & pause)
if %c%==3 (powershell -ExecutionPolicy Bypass -File "download_bbc.ps1" & echo. & pause)
if %c%==4 start "" notepad "sbs_queue.txt"
if %c%==5 start "" notepad "bbc_queue.txt"
if %c%==6 start "" notepad "downloaded.txt"
if %c%==7 goto :eof
goto menu
