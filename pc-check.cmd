@echo off
rem pc-check per Doppelklick starten: fragt nach Adminrechten (UAC) und oeffnet das Script
rem in einem eigenen PowerShell-Fenster, das nach dem Lauf offen bleibt.
rem -ExecutionPolicy Bypass gilt nur fuer diesen einen Aufruf und aendert keine Einstellung.
setlocal
set "PCCHECK=%~dp0pc-check.ps1"
if not exist "%PCCHECK%" (
    echo pc-check.ps1 wurde nicht gefunden. Bitte alle Dateien im selben Ordner lassen.
    pause
    exit /b 1
)
rem Erst ohne Adminrechte: pc-check-start.ps1 waehlt die sichere Fassung (installiert unter Program Files, falls aktuell)
rem Voller Pfad (2.3.3): sonst saehe cmd zuerst im aktuellen Ordner nach einer powershell.exe
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-check-start.ps1"
if errorlevel 1 (
    echo Der Start wurde abgebrochen, z. B. weil die Adminabfrage abgelehnt wurde.
    pause
)
