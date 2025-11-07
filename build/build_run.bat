@echo off

:: 1. Define the build command and output file path
set ODIN_BUILD_CMD=odin build "..\\src" -build-mode:exe -subsystem:console -target-features:"sse2" -target:windows_amd64 -thread-count:12 -o:speed -out:"wingen.exe"
set EXE_PATH=.\wingen.exe

:: 2. Execute the build command
echo Running build command: %ODIN_BUILD_CMD%
%ODIN_BUILD_CMD%
if errorlevel 1 goto :BUILD_FAILED

:: 3. Execute the built program if the build succeeded
echo.
echo === Build Succeeded. Running Program ===
%EXE_PATH%

goto :EOF

:BUILD_FAILED
echo.
echo === Build Failed! Not running program. ===
exit /b 1
