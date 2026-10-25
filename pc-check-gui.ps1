<#
.SYNOPSIS
    pc-check GUI: startet den lokalen Server (nur 127.0.0.1) und öffnet die Oberfläche als App-Fenster in Microsoft Edge.
.DESCRIPTION
    Der Scan (pc-check.ps1) bleibt rein lesend. Änderungen am System kann nur die GUI auslösen, und nur mit Wiederherstellungspunkt.
    Architektur und Sicherheitsregeln: docs/gui-architektur.md
.PARAMETER Port
    Fester Port. Ohne Angabe wird ein freier Port gewählt.
.PARAMETER NoBrowser
    Kein Edge starten, stattdessen die URL samt Token in der Konsole ausgeben (für Tests).
.PARAMETER NoElevate
    Sich nicht mit Adminrechten neu starten (für Tests).
.PARAMETER SafetyLib
    Nur für Tests: Pfad zu einer alternativen Safety.ps1 statt gui\lib\Safety.ps1.
.PARAMETER ReadOnly
    Nur-Lesen-Modus erzwingen: Ändern, Rückgängig und Scan sind gesperrt.
.PARAMETER NoInstallPrompt
    Nur für Tests: Bei einem ungesicherten Ordner nicht nach der Installation fragen, sondern direkt im Nur-Lesen-Modus starten.
.NOTES
    Sicherheit: Die GUI führt ihren Code mit Adminrechten aus. Liegt er in einem Ordner, den auch Programme ohne
    Adminrechte ändern können, bietet das Skript an, Morpheus nach C:\Program Files\Morpheus zu installieren und von dort zu
    starten. Daten (Berichte, Journal, Checkliste, Akzeptanzliste) liegen dann in C:\ProgramData\Morpheus, ebenfalls nur für
    Administratoren beschreibbar. Lehnt man ab (oder fehlen die Adminrechte), läuft die GUI im Nur-Lesen-Modus.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 65535)][int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$NoElevate,
    [string]$SafetyLib,
    [switch]$ReadOnly,
    [switch]$NoInstallPrompt
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 1. Adminrechte: sonst mit UAC neu starten
if ((-not $isAdmin) -and (-not $NoElevate)) {
    # Erst ohne Adminrechte prüfen: Ist dieser Ordner ungesichert, die Installation unter Program Files aber aktuell,
    # wird direkt die installierte Fassung erhöht gestartet. Der Code aus dem ungesicherten Ordner bekommt dann nie
    # Adminrechte; das passiert nur noch zum Installieren bzw. Aktualisieren (mit Rückfrage).
    $target = $PSCommandPath
    try {
        . (Join-Path $Root 'gui\lib\Install.ps1')
        $inst = Join-Path $env:ProgramFiles 'Morpheus'
        if ((-not (Test-MorpheusCodeSecure -Root $Root).Sicher) -and (Test-MorpheusCodeSecure -Root $inst).Sicher -and (Test-MorpheusInstallCurrent -Source $Root -Target $inst)) {
            $target = Join-Path $inst 'pc-check-gui.ps1'
            Write-Host "Starte die installierte Fassung aus $inst." -ForegroundColor Green
        }
    }
    catch { $target = $PSCommandPath }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $target
    if ($Port -gt 0) { $argLine += " -Port $Port" }
    if ($NoBrowser) { $argLine += ' -NoBrowser' }
    if ($SafetyLib) { $argLine += (' -SafetyLib "{0}"' -f $SafetyLib) }
    if ($ReadOnly) { $argLine += ' -ReadOnly' }
    if ($NoInstallPrompt) { $argLine += ' -NoInstallPrompt' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine }
    catch { Write-Host 'Der Start wurde abgebrochen, z. B. weil die Adminabfrage abgelehnt wurde.' -ForegroundColor Yellow; Read-Host 'Enter zum Schließen' | Out-Null }
    return
}

# 2. Einzelinstanz
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, 'Global\pc-check-gui', [ref]$createdNew)
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) {
    Write-Host 'pc-check GUI läuft bereits. Bitte das vorhandene Fenster benutzen (oder die laufende Instanz beenden).' -ForegroundColor Yellow
    if (-not $NoBrowser) { Read-Host 'Enter zum Schließen' | Out-Null }
    return
}

$edge = $null
try {
    # 3. Module laden (Dot-Source im Script-Scope, damit alle Funktionen sichtbar sind)
    . (Join-Path $Root 'gui\lib\Install.ps1')
    . (Join-Path $Root 'gui\lib\Server.ps1')
    $safetyPath = Join-Path $Root 'gui\lib\Safety.ps1'
    if ($SafetyLib) { $safetyPath = (Resolve-Path -LiteralPath $SafetyLib).Path }
    if (Test-Path -LiteralPath $safetyPath -PathType Leaf) { . $safetyPath }
    else { Write-Host 'Hinweis: gui\lib\Safety.ps1 fehlt, Änderungen sind noch nicht verfügbar.' -ForegroundColor Yellow }

    # 3a. Ist der Codeordner gesichert? Nur Administratoren, SYSTEM und TrustedInstaller dürfen Code und Ordner ändern.
    # Sonst könnte ein Programm ohne Adminrechte den Code austauschen, den die GUI hier mit Adminrechten ausführt.
    $dataRoot = $Root           # Datenordner (Berichte, Journal, Checkliste, Akzeptanzliste)
    $roMode = $false            # Nur-Lesen-Modus
    $roReason = $null
    $installTarget = Join-Path $env:ProgramFiles 'Morpheus'
    if (-not $isAdmin) {
        $roMode = $true
        $roReason = 'Morpheus läuft ohne Administratorrechte.'
    }
    else {
        $codeCheck = Test-MorpheusCodeSecure -Root $Root
        if ($codeCheck.Sicher) {
            # Gesicherter Betrieb (z. B. aus C:\Program Files\Morpheus): Daten in C:\ProgramData\Morpheus, bei jedem Start geprüft
            try { $dataRoot = Initialize-MorpheusDataDir }
            catch {
                $roMode = $true
                $roReason = 'Der Datenordner unter ProgramData lässt sich nicht sichern: ' + $_.Exception.Message
                Write-Host $roReason -ForegroundColor Yellow
            }
        }
        else {
            $grund = [string]$codeCheck.Gruende[0]
            $roReason = "Morpheus läuft aus einem Ordner, den auch Programme ohne Administratorrechte ändern können (Grund: $grund)."
            $roMode = $true
            if ($ReadOnly -or $NoInstallPrompt) {
                # kein Nachfragen: Nur-Lesen
            }
            else {
                Write-Host ''
                Write-Host "Morpheus läuft aus einem Ordner, den auch Programme ohne Administratorrechte ändern können (Grund: $grund)." -ForegroundColor Yellow
                foreach ($more in @($codeCheck.Gruende | Select-Object -Skip 1 -First 3)) { Write-Host "  weiterer Grund: $more" -ForegroundColor Yellow }
                Write-Host "Damit Änderungen sicher sind, wird Morpheus nach $installTarget installiert bzw. aktualisiert und von dort gestartet."
                $answer = Read-Host 'Installieren? [J/n]'
                if (($answer -eq '') -or ($answer -match '^\s*(j|ja|y|yes)\s*$')) {
                    try {
                        if (Test-MorpheusInstallCurrent -Source $Root -Target $installTarget) {
                            Write-Host "Die installierte Version in $installTarget ist aktuell, sie wird gestartet." -ForegroundColor Green
                        }
                        else {
                            Write-Host "Installiere nach $installTarget ..."
                            [void](Install-Morpheus -Source $Root -Target $installTarget)
                            Write-Host 'Installation abgeschlossen (Startmenü: "Morpheus - PC Check-up").' -ForegroundColor Green
                        }
                        # Eigenen Mutex freigeben, sonst weist sich die installierte Instanz selbst ab
                        if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { }; $hasMutex = $false }
                        $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $installTarget 'pc-check-gui.ps1')))
                        if ($Port -gt 0) { $al += @('-Port', [string]$Port) }
                        if ($NoBrowser) { $al += '-NoBrowser' }
                        Start-Process -FilePath 'powershell.exe' -ArgumentList $al
                        return
                    }
                    catch {
                        Write-Host ('Die Installation ist fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
                        $roReason += ' Die Installation ist fehlgeschlagen: ' + $_.Exception.Message
                    }
                }
                else { $roReason += ' Die Installation wurde abgelehnt.' }
            }
        }
    }
    if ($ReadOnly -and (-not $roMode)) {
        $roMode = $true
        $roReason = 'Der Nur-Lesen-Modus wurde mit -ReadOnly erzwungen.'
    }
    if ($roMode) { Write-Host "Nur-Lesen-Modus: $roReason" -ForegroundColor Yellow }

    # 4. Port und Token
    if ($Port -eq 0) {
        $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
        $tcp.Start(); $Port = $tcp.LocalEndpoint.Port; $tcp.Stop()
    }
    # Das Token verlässt den Server nur über /api/session/claim. In die Adresse (und damit in die
    # für alle Benutzerprozesse lesbare Befehlszeile von Edge) kommt nur ein Einmal-Code.
    $token = New-GuiSecret
    $boot = New-GuiSecret

    # 5. Server starten
    Initialize-GuiServer -Root $Root -Port $Port -Token $token -BootCode $boot -SafetyPath $safetyPath -DataRoot $dataRoot -ReadOnly:$roMode -ReadOnlyReason $roReason
    $url = "http://127.0.0.1:$Port/#b=$boot"

    # 6. Fenster: Edge als App-Fenster mit eigenem Profil, sonst Standardbrowser
    if ($NoBrowser) {
        Write-Host "GUI läuft auf: $url" -ForegroundColor Green
        Write-Host '(Beenden: POST /api/shutdown oder Strg+C)'
    }
    else {
        $edgeExe = $null
        foreach ($c in @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $edgeExe = $c; break }
        }
        if ($edgeExe) {
            $profile = Join-Path $env:LOCALAPPDATA 'pc-check\edge'
            [void](New-Item -ItemType Directory -Path $profile -Force)
            # --start-maximized: bildschirmfüllend (ein App-Fenster merkt sich sonst die letzte Größe)
            Start-Process -FilePath $edgeExe -ArgumentList @("--app=$url", "--user-data-dir=`"$profile`"", '--start-maximized')
            $edge = $profile
            Write-Host 'GUI läuft ... (Fenster schließen beendet)' -ForegroundColor Green
        }
        else {
            Write-Host 'Microsoft Edge wurde nicht gefunden, der Standardbrowser wird geöffnet.' -ForegroundColor Yellow
            Start-Process $url
            Write-Host 'GUI läuft ... (Ende erkennt nur der Heartbeat der geöffneten Seite)' -ForegroundColor Green
        }
    }

    # 7. Hauptschleife
    $reason = Start-GuiServerLoop -EdgeProfile $edge
    Write-Host "GUI beendet ($reason)."
}
catch {
    $msg = $_.Exception.Message
    Write-Host "Fehler beim Start der GUI: $msg" -ForegroundColor Red
    if ($msg -match 'Zugriff|denied|5\b') { Write-Host 'Tipp: Als Administrator starten (pc-check-gui.cmd).' -ForegroundColor Yellow }
    if (-not $NoBrowser) { Read-Host 'Enter zum Schließen' | Out-Null }
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
