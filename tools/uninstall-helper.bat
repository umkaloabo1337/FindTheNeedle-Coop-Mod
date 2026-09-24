@echo off
rem ---------------------------------------------------------------------
rem  Find The Needle co-op mod - optional uninstall helper
rem
rem  Removes the mod's line from the game's override.cfg, and the
rem  [autoload] header too if nothing else is using it. The "mods" folder
rem  can then be deleted. Nothing else was ever changed.
rem
rem  Put this file next to FindTheNeedle.exe and run it.
rem ---------------------------------------------------------------------
setlocal

set "GAME=%~dp0"
set "GAME=%GAME:~0,-1%"
set "CFG=%GAME%\override.cfg"

if not exist "%CFG%" (
    echo.
    echo   No override.cfg here, nothing to undo.
    echo   No hay override.cfg aqui, no hay nada que deshacer.
    echo.
    pause
    exit /b 0
)

findstr /v /b /i "MPMod=" "%CFG%" > "%CFG%.t1" 2>nul

rem keep the [autoload] header only if some other autoload still uses it
findstr /r "^[A-Za-z_][A-Za-z0-9_]*=.**" "%CFG%.t1" 2>nul > "%CFG%.t3"
set "OTHERS=0"
for %%A in ("%CFG%.t3") do if not "%%~zA"=="0" set "OTHERS=1"

if "%OTHERS%"=="0" (
    findstr /v /l /b /i /c:"[autoload]" "%CFG%.t1" > "%CFG%"
) else (
    copy /y "%CFG%.t1" "%CFG%" >nul
)
del "%CFG%.t1" "%CFG%.t3" >nul 2>&1

echo.
echo   Done. You can delete the "mods" folder now.
echo   Listo. Ya puedes borrar la carpeta "mods".
echo.
pause
