@echo off

set build-flags=-warnings-as-errors -vet-cast -vet-shadowing -error-pos-style:unix -subsystem:windows
set debug-flags=-debug -o:none

IF NOT EXIST .\build mkdir .\build
REM TODO shipping build

REM debug build
del .\build\*.pdb
odin build game -build-mode:dll -out:.\build\game.dll %build-flags% %debug-flags% -pdb-name:.\build\game-%random%.pdb
odin build . -out:.\build\debug.exe %build-flags% %debug-flags% -define:INTERNAL=true

exit /b 0