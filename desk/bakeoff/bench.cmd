@echo off
rem WetOwl Desk bake-off: each booth plays and mixes for 30 seconds while it measures
rem itself, then closes. Leave the windows alone while they run. Afterwards, send the
rem "results" folder (JSON reports and screenshots). Best on a 1920x1080 (or larger)
rem screen: Slint is drawn 1:1 in pixels and egui scales its 1920x1080 design to fit,
rem whatever Windows' display scaling.
cd /d %~dp0
if not exist results mkdir results
echo egui (wgpu)...
desk-egui.exe --bench 30 --out results
echo egui (OpenGL)...
set WO_RENDERER=glow
desk-egui.exe --bench 30 --out results
set WO_RENDERER=
echo Slint (femtovg, then Skia)...
set SLINT_SCALE_FACTOR=1
desk-slint.exe --bench 30 --out results
set WO_RENDERER=skia
desk-slint.exe --bench 30 --out results
set WO_RENDERER=
set SLINT_SCALE_FACTOR=
echo.
echo Done. Send the "results" folder.
pause
