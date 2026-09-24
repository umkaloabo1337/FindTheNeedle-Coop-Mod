@echo off
rem Starts the game with dev/tool_poser.gd from this repo, and puts the
rem mod's own line back in override.cfg when the game closes.
rem Set GAME_DIR first if the game is not in the default Steam folder.
setlocal
set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Find The Needle Demo"
if defined GAME_DIR set "GAME=%GAME_DIR%"
for %%I in ("%~dp0..") do set "SRC=%%~fI"
if not exist "%GAME%\FindTheNeedle.exe" (echo No encuentro el juego en "%GAME%". & pause & exit /b 1)
tasklist | find /i "FindTheNeedle.exe" >nul && (echo Cierra antes el juego. & pause & exit /b 1)
set "CFG=%GAME%\override.cfg"
if exist "%CFG%" copy /y "%CFG%" "%CFG%.poser_backup" >nul
rem our two autoload lines, plus anything else the file already had
if exist "%CFG%" (findstr /v /b /i /l /c:"MPMod=" /c:"ToolPoser=" /c:"[autoload]" "%CFG%" > "%CFG%.tmp") else (type nul > "%CFG%.tmp")
set "S=%SRC:\=/%"
(
echo [autoload]
echo MPMod="*%S%/mods/multiplayer/mp.gd"
echo ToolPoser="*%S%/dev/tool_poser.gd"
type "%CFG%.tmp"
) > "%CFG%"
del "%CFG%.tmp"
echo Posicionador de herramientas abierto. F9 guarda, cierra el juego al terminar.
start "" /wait /d "%GAME%" "%GAME%\FindTheNeedle.exe"
rem keep whatever the game wrote while it ran (graphics settings and so on),
rem just swap our two lines back for the original MPMod one
findstr /v /b /i /l /c:"MPMod=" /c:"ToolPoser=" /c:"[autoload]" "%CFG%" > "%CFG%.tmp"
(
echo [autoload]
if exist "%CFG%.poser_backup" findstr /b /i /l /c:"MPMod=" "%CFG%.poser_backup"
type "%CFG%.tmp"
) > "%CFG%"
del "%CFG%.tmp"
if exist "%CFG%.poser_backup" del "%CFG%.poser_backup"
echo Listo, override.cfg como estaba.
pause
