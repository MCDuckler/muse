@echo off
rem WetOwl Desk bake-off: each booth plays and mixes for 30 seconds while it measures
rem itself, then closes. Leave the windows alone while they run. Afterwards, send the
rem "results" folder (JSON reports and screenshots).
cd /d %~dp0
if not exist results mkdir results
echo egui (wgpu)...
desk-egui.exe --bench 30 --out results
echo egui (OpenGL)...
set WO_RENDERER=glow
desk-egui.exe --bench 30 --out results
set WO_RENDERER=
echo Slint (femtovg, then Skia)...
desk-slint.exe --bench 30 --out results
set WO_RENDERER=skia
desk-slint.exe --bench 30 --out results
set WO_RENDERER=
echo.
echo Done. Send the "results" folder.
pause
