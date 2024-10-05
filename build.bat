@echo off

set build-flags=-warnings-as-errors -vet-cast -vet-shadowing -error-pos-style:unix -subsystem:windows
set debug-flags=-debug -o:none

IF NOT EXIST .\build mkdir .\build
:: TODO shipping build

:: Debug build
del .\build\*.pdb
odin build game -build-mode:dll -out:.\build\game.dll %build-flags% %debug-flags% -pdb-name:.\build\game-%random%.pdb

:: if the game is already running exit early
set EXE=debug.exe
for /f %%x in ('tasklist /NH /FI "IMAGENAME eq %EXE%"') do if %%x == %EXE% exit /b 0

odin build . -out:.\build\%EXE% %build-flags% %debug-flags% -define:INTERNAL=true

exit /b 0