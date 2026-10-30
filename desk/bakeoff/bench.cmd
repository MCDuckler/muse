@echo off
rem WetOwl Desk bench: the booth plays and mixes for 30 seconds while it measures
rem itself, then closes. Leave the windows alone while they run. Afterwards, send the
rem "results" folder (JSON reports and screenshots). Best on a 1920x1080 (or larger)
rem screen (the booth scales its 1920x1080 design down to fit a smaller window).
cd /d %~dp0
if not exist results mkdir results
echo egui (wgpu)...
wetowl-desk.exe --bench 30 --out results
echo egui (OpenGL)...
set WO_RENDERER=glow
wetowl-desk.exe --bench 30 --out results
set WO_RENDERER=
echo.
echo Done. Send the "results" folder.
pause
