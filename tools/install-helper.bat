@echo off
rem ---------------------------------------------------------------------
rem  Find The Needle co-op mod - optional install helper
rem
rem  Does the second install step for you: adds the mod's line to the
rem  game's override.cfg. You can do the same by hand with Notepad; see
rem  mods\multiplayer\README.txt.
rem
rem  Put this file next to FindTheNeedle.exe and run it, after copying
rem  the "mods" folder there. Running it twice is harmless.
rem
rem  Not in the Nexus download on purpose: Nexus quarantines uploads that
rem  contain scripts, and this one only saves you a copy and paste.
rem ---------------------------------------------------------------------
setlocal

set "GAME=%~dp0"
set "GAME=%GAME:~0,-1%"

if not exist "%GAME%\FindTheNeedle.exe" (
    echo.
    echo   FindTheNeedle.exe is not in this folder:
    echo     %GAME%
    echo   Put this file next to the game and run it again.
    echo   Pon este archivo junto al juego y ejecutalo otra vez.
    echo.
    pause
    exit /b 1
)

if not exist "%GAME%\mods\multiplayer\mp.gd" (
    echo.
    echo   The mod is not here yet: copy the "mods" folder next to
    echo   FindTheNeedle.exe first, then run this again.
    echo   Copia antes la carpeta "mods" junto a FindTheNeedle.exe.
    echo.
    pause
    exit /b 1
)

set "CFG=%GAME%\override.cfg"
if not exist "%CFG%" (type nul > "%CFG%")

rem Drop our line, so running this twice cannot duplicate it.
findstr /v /b /i "MPMod=" "%CFG%" > "%CFG%.t1" 2>nul

rem Does an autoload that is not ours remain? Their values start with ="*
rem If one does, the [autoload] header belongs to the game and has to stay.
findstr /r "^[A-Za-z_][A-Za-z0-9_]*=.**" "%CFG%.t1" 2>nul > "%CFG%.t3"
set "OTHERS=0"
for %%A in ("%CFG%.t3") do if not "%%~zA"=="0" set "OTHERS=1"

if "%OTHERS%"=="0" (
    findstr /v /l /b /i /c:"[autoload]" "%CFG%.t1" > "%CFG%.t2"
) else (
    copy /y "%CFG%.t1" "%CFG%.t2" >nul
)

> "%CFG%" (
    type "%CFG%.t2"
    echo [autoload]
    echo MPMod="*mods/multiplayer/mp.gd"
)
del "%CFG%.t1" "%CFG%.t2" "%CFG%.t3" >nul 2>&1

echo.
echo   Done. Open the game FROM STEAM: the menu has MULTIPLAYER (F2 in game).
echo   Listo. Abre el juego DESDE STEAM: en el menu aparece MULTIPLAYER.
echo.
echo   Run this again after every game update: updates reset override.cfg.
echo   Ejecutalo otra vez tras cada actualizacion del juego.
echo.
pause
