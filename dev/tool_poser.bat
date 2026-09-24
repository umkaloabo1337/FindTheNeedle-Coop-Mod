@echo off
rem Starts the game with dev/tool_poser.gd from this repo, and puts
rem override.cfg back the way it was when the game closes.
rem Set GAME_DIR first if the game is not in the default Steam folder.
setlocal
set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Find The Needle Demo"
if defined GAME_DIR set "GAME=%GAME_DIR%"
for %%I in ("%~dp0..") do set "SRC=%%~fI"
if not exist "%GAME%\FindTheNeedle.exe" (echo No encuentro el juego en "%GAME%". & pause & exit /b 1)
tasklist | find /i "FindTheNeedle.exe" >nul && (echo Cierra antes el juego. & pause & exit /b 1)
if exist "%GAME%\override.cfg" copy /y "%GAME%\override.cfg" "%GAME%\override.cfg.poser_backup" >nul
set "S=%SRC:\=/%"
(
echo [autoload]
echo MPMod="*%S%/mods/multiplayer/mp.gd"
echo ToolPoser="*%S%/dev/tool_poser.gd"
) > "%GAME%\override.cfg"
echo Posicionador de herramientas abierto. F9 guarda, cierra el juego al terminar.
start "" /wait /d "%GAME%" "%GAME%\FindTheNeedle.exe"
if exist "%GAME%\override.cfg.poser_backup" (
  move /y "%GAME%\override.cfg.poser_backup" "%GAME%\override.cfg" >nul
) else (
  del "%GAME%\override.cfg"
)
echo Listo, override.cfg como estaba.
pause
