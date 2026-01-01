@ECHO off

ECHO "Choose your backend"
ECHO 1. c backend
ECHO 2. js backend
SET /p backend= "Backend: "

if /i "%backend%"=="1" goto c_backend
if /i "%backend%"=="2" goto js_backend

:c_backend
ECHO compile c
nim c "%~dpn1.nim"
goto done

:js_backend
ECHO compile js
nim js -d:release "%~dpn1.nim"
goto done

:done
pause