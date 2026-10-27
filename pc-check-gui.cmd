@echo off
rem Morpheus (pc-check-GUI) per Doppelklick starten: fragt nach Adminrechten (UAC) und startet den lokalen Server
rem samt App-Fenster (Edge). -ExecutionPolicy Bypass gilt nur fuer diesen einen Aufruf und aendert keine Einstellung.
setlocal
set "PCCHECKGUI=%~dp0pc-check-gui.ps1"
if not exist "%PCCHECKGUI%" (
    echo pc-check-gui.ps1 wurde nicht gefunden. Bitte alle Dateien im selben Ordner lassen.
    pause
    exit /b 1
)
rem Erst ohne Adminrechte starten: das Script entscheidet, welche Fassung erhoeht gestartet wird
rem (die installierte unter Program Files, falls aktuell; sonst diese zum Installieren).
rem Voller Pfad (2.3.3): sonst saehe cmd zuerst im aktuellen Ordner nach einer powershell.exe
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%PCCHECKGUI%"
if errorlevel 1 (
    echo Der Start wurde abgebrochen, z. B. weil die Adminabfrage abgelehnt wurde.
    pause
)
