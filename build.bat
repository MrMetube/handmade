@echo off

set build-flags=-warnings-as-errors -vet-cast -vet-shadowing -error-pos-style:unix -subsystem:windows
set debug-flags=-debug -o:none

if not exist .\build mkdir .\build
if not exist .\data  mkdir .\data

:: Debug build
set EXE=debug.exe

:: Game
if exist .\build\*.pdb del .\build\*.pdb
echo WAITING FOR PDB > lock.tmp
odin build game -build-mode:dll -out:.\build\game.dll %build-flags% %debug-flags% -pdb-name:.\build\game-%random%.pdb
del lock.tmp
if errorlevel 1 exit /b 1

:: exit early if the game is running
for /f %%x in ('tasklist /NH /FI "IMAGENAME eq %EXE%"') do if %%x == %EXE% exit /b 0

:: Platform
odin build . -out:.\build\%EXE% %build-flags% %debug-flags% -define:INTERNAL=true
if errorlevel 1 exit /b 1

exit /b 0