@echo off
REM Every offline check in one go: syntax, l10n harness, l10n manifest,
REM manager harness, modmain harness. Stops at the first failure. Rendering/HUD
REM still needs tests\preview\run.sh and engine behaviour still needs a human
REM in-game run (see CLAUDE.md).
REM
REM Call it from the repo root as:  .\verify
REM Override the interpreters with LUA=... / LUAC=... in the environment.
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not defined LUA  set "LUA=C:\Program Files (x86)\Lua\5.1\lua.exe"
if not defined LUAC set "LUAC=C:\Program Files (x86)\Lua\5.1\luac.exe"

set "FAILED=0"

echo == syntax (luac -p) ==
for /r %%f in (*.lua) do (
    "%LUAC%" -p "%%~ff"
    if errorlevel 1 set "FAILED=1"
)
if "!FAILED!"=="1" goto :fail
echo ok

echo == l10n harness ==
"%LUA%" "tests\l10n_test.lua"
if errorlevel 1 set "FAILED=1"
if "!FAILED!"=="1" goto :fail

echo == l10n manifest ==
"%LUA%" "tools\gen_l10n.lua" --check
if errorlevel 1 set "FAILED=1"
if "!FAILED!"=="1" goto :fail

echo == manager harness ==
"%LUA%" "tests\manager_test.lua"
if errorlevel 1 set "FAILED=1"
if "!FAILED!"=="1" goto :fail

echo == modmain harness ==
"%LUA%" "tests\modmain_test.lua"
if errorlevel 1 set "FAILED=1"
if "!FAILED!"=="1" goto :fail

echo All checks passed.
exit /b 0

:fail
echo.
echo Verification failed.
exit /b 1
