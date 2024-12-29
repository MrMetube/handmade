@echo off

set pedantic=-vet-unused-imports -warnings-as-errors -vet-unused-variables -vet-packages:main,game -vet-unused-procedures -vet-style
set flags=-vet-cast -vet-shadowing -error-pos-style:unix -subsystem:windows
set debug=-debug -define:INTERNAL=true -o:none

if not exist .\build mkdir .\build
if not exist .\data  mkdir .\data

:: Debug build
set EXE=debug.exe

:: Game
if exist .\build\*.pdb del .\build\*.pdb
echo WAITING FOR PDB > lock.tmp
odin build game -build-mode:dll -out:.\build\game.dll -pdb-name:.\build\game-%random%.pdb %flags% %debug% 
del lock.tmp
if errorlevel 1 exit /b 1

:: exit early if the game is running
for /f %%x in ('tasklist /NH /FI "IMAGENAME eq %EXE%"') do if %%x == %EXE% exit /b 0

:: Platform
odin build . -out:.\build\%EXE% %flags% %debug%
if errorlevel 1 exit /b 1

exit /b 0