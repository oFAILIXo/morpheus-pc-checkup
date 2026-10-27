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
# Sicherheit (2.3.3): Module nur aus System32 und Program Files laden, nie aus Benutzerordnern (gui\lib\Systempfade.ps1).
# Als erste Anweisung, damit vorher nichts automatisch geladen wird; Kindprozesse und Jobs erben den Wert.
$env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;' + [Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules'
# Kindprozesse (Jobs, Scan, winget, Windows-Programme): PATH nur Systemordner, keine .NET-Profiler-Variablen aus der
# Benutzerumgebung (HKCU\Environment), über die sich eine DLL in jeden .NET-Prozess laden ließe (2.3.3, N6)
$env:PATH = [Environment]::SystemDirectory + ';' + [Environment]::GetFolderPath('Windows') + ';' + [Environment]::SystemDirectory + '\Wbem;' + [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0'
foreach ($morpheusVar in @([Environment]::GetEnvironmentVariables().Keys)) { if ([string]$morpheusVar -match '^(COR_|CORECLR_|COMPlus_|DOTNET_)') { [Environment]::SetEnvironmentVariable([string]$morpheusVar, $null) } }

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# Programme nur mit vollem Pfad (Systemordner über die Windows-API, nicht über Umgebungsvariablen)
$psExe = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 1. Adminrechte: sonst mit UAC neu starten
if ((-not $isAdmin) -and (-not $NoElevate)) {
    # Erst ohne Adminrechte prüfen: Ist dieser Ordner ungesichert, die Installation unter Program Files aber aktuell,
    # wird direkt die installierte Fassung erhöht gestartet. Der Code aus dem ungesicherten Ordner bekommt dann nie
    # Adminrechte; das passiert nur noch zum Installieren bzw. Aktualisieren (mit Rückfrage).
    $target = $PSCommandPath
    try {
        . (Join-Path $Root 'gui\lib\Install.ps1')
        $inst = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Morpheus'
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
    try { Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argLine }
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
$repTemp = $null   # nur für die Reparatur angelegter Temp-Ordner, wird beim Beenden entfernt
try {
    # 3. Module laden (Dot-Source im Script-Scope, damit alle Funktionen sichtbar sind)
    . (Join-Path $Root 'gui\lib\Install.ps1')
    . (Join-Path $Root 'gui\lib\Server.ps1')
    $safetyPath = Join-Path $Root 'gui\lib\Safety.ps1'
    if ($SafetyLib) { $safetyPath = (Resolve-Path -LiteralPath $SafetyLib).Path }
    if (Test-Path -LiteralPath $safetyPath -PathType Leaf) { . $safetyPath }
    else { Write-Host 'Hinweis: gui\lib\Safety.ps1 fehlt, Änderungen sind noch nicht verfügbar.' -ForegroundColor Yellow }
    $defenderPath = Join-Path $Root 'gui\lib\Defender.ps1'
    if (Test-Path -LiteralPath $defenderPath -PathType Leaf) { . $defenderPath }
    else { Write-Host 'Hinweis: gui\lib\Defender.ps1 fehlt, die Defender-Werkzeuge sind noch nicht verfügbar.' -ForegroundColor Yellow }
    $sysPath = Join-Path $Root 'gui\lib\Sysinternals.ps1'
    if (Test-Path -LiteralPath $sysPath -PathType Leaf) { . $sysPath }
    else { Write-Host 'Hinweis: gui\lib\Sysinternals.ps1 fehlt, die Sysinternals-Werkzeuge sind noch nicht verfügbar.' -ForegroundColor Yellow }

    $wingetPath = Join-Path $Root 'gui\lib\Winget.ps1'
    if (Test-Path -LiteralPath $wingetPath -PathType Leaf) { . $wingetPath }
    else { Write-Host 'Hinweis: gui\lib\Winget.ps1 fehlt, der Update-Dialog ist noch nicht verfügbar.' -ForegroundColor Yellow }
    $wartungPath = Join-Path $Root 'gui\lib\Wartung.ps1'
    if (Test-Path -LiteralPath $wartungPath -PathType Leaf) { . $wartungPath }
    else { Write-Host 'Hinweis: gui\lib\Wartung.ps1 fehlt, die Wartungswerkzeuge sind noch nicht verfügbar.' -ForegroundColor Yellow }

    $akzPath = Join-Path $Root 'gui\lib\Akzeptanz.ps1'
    if (Test-Path -LiteralPath $akzPath -PathType Leaf) { . $akzPath }
    else { Write-Host 'Hinweis: gui\lib\Akzeptanz.ps1 fehlt, die Akzeptanzliste ist noch nicht verfügbar.' -ForegroundColor Yellow }
    # Sichere Pfade für Programme und Temp (2.3.3)
    $pfadPath = Join-Path $Root 'gui\lib\Systempfade.ps1'
    if (Test-Path -LiteralPath $pfadPath -PathType Leaf) { . $pfadPath }

    # 3a. Ist der Codeordner gesichert? Nur Administratoren, SYSTEM und TrustedInstaller dürfen Code und Ordner ändern.
    # Sonst könnte ein Programm ohne Adminrechte den Code austauschen, den die GUI hier mit Adminrechten ausführt.
    $dataRoot = $Root           # Datenordner (Berichte, Journal, Checkliste, Akzeptanzliste)
    $roMode = $false            # Nur-Lesen-Modus
    $roReason = $null
    $tempFehler = $null
    $tempSicher = $false          # gesicherter Temp-Ordner für den Bestätigungsdialog der Reparatur gesetzt
    $datenordnerZustand = $null   # nur bei reparierbarem Datenordner (18.10)
    $datenordnerPfad = $null
    $installTarget = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Morpheus'
    if (-not $isAdmin) {
        $roMode = $true
        $roReason = 'Morpheus läuft ohne Administratorrechte.'
    }
    else {
        $codeCheck = Test-MorpheusCodeSecure -Root $Root
        if ($codeCheck.Sicher) {
            # Gesicherter Betrieb (z. B. aus C:\Program Files\Morpheus): Daten in C:\ProgramData\Morpheus, bei jedem Start geprüft
            try {
                $dataRoot = Initialize-MorpheusDataDir
                # TEMP in den gesicherten Datenordner: Add-Type kompiliert dort und lädt die DLL danach (2.3.3)
                # Ohne gesicherten Temp-Ordner Nur-Lesen-Modus: Sonst kompilierte der Bestätigungsdialog im Temp des Benutzers
                if (-not (Get-Command -Name Set-MorpheusTempPfad -CommandType Function -ErrorAction SilentlyContinue)) { throw 'gui\lib\Systempfade.ps1 fehlt, der Temp-Ordner lässt sich nicht sichern.' }
                if (-not (Set-MorpheusTempPfad -DataRoot $dataRoot)) { throw 'Der Temp-Ordner im Datenordner ließ sich nicht sichern.' }
            }
            catch {
                $roMode = $true
                $dz = $null
                if ($_.Exception.Data.Contains('datenordner') -and ([string]$_.Exception.Data['datenordner'] -ceq 'reparierbar')) { $dz = $_.Exception.Data['zustand'] }
                if ($dz) {
                    # Der Bestätigungsdialog der Reparatur kompiliert beim ersten Aufruf C# (Add-Type, DLL in %TEMP%).
                    # Dafür ein frischer, gesicherter Temp-Ordner (nicht der Temp-Ordner des Benutzers). Scheitert das: keine Reparatur anbieten.
                    $tempFehler = $null
                    try {
                        if (-not (Get-Command -Name New-MorpheusSecureDirectory -CommandType Function -ErrorAction SilentlyContinue)) { throw 'New-MorpheusSecureDirectory fehlt.' }
                        if (-not (Get-Command -Name Set-MorpheusTempPfad -CommandType Function -ErrorAction SilentlyContinue)) { throw 'gui\lib\Systempfade.ps1 fehlt.' }
                        $zufall = New-Object byte[] 8
                        $rngT = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                        try { $rngT.GetBytes($zufall) } finally { $rngT.Dispose() }
                        $repTempNeu = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('Morpheus-Temp-' + (($zufall | ForEach-Object { $_.ToString('x2') }) -join ''))
                        New-MorpheusSecureDirectory -Path $repTempNeu
                        $repTemp = $repTempNeu   # ab hier wird er beim Beenden entfernt
                        if (-not (Set-MorpheusTempPfad -DataRoot $repTemp)) { throw 'Der Temp-Ordner ließ sich nicht sichern.' }
                        $tempSicher = $true
                    }
                    catch { $tempFehler = $_.Exception.Message }
                    if ($tempFehler) {
                        $dz = $null
                        $roReason = 'Die Rechte des Datenordners unter ProgramData wurden geändert. Eine Reparatur in Morpheus ist nicht möglich, weil kein gesicherter Temp-Ordner angelegt werden konnte (' + $tempFehler + '). Bitte als Administrator reparieren oder neu installieren.'
                    }
                }
                if ($dz) {
                    # Datenordner mit zusätzlichen Rechten (meist „Fortsetzen“ im Explorer): Reparatur über die GUI möglich (18.10)
                    $datenordnerZustand = $dz
                    if (Get-Command -Name MorpheusDefaultDataDir -CommandType Function -ErrorAction SilentlyContinue) { $datenordnerPfad = [string](MorpheusDefaultDataDir) }
                    else { $datenordnerPfad = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Morpheus' }
                    $kn = @()
                    foreach ($k in @($dz.konten)) { if ($k -and $k.name) { $kn += ([string]$k.name -replace '[\u0000-\u001F\u007F\u0085\u061C\u200B-\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069\uFEFF]', ' ') } }
                    $roReason = 'Die Rechte des Datenordners unter ProgramData wurden geändert, auch Programme ohne Administratorrechte könnten dort schreiben'
                    if ($kn.Count -gt 0) { $roReason += ' (Konten: ' + ($kn -join ', ') + ')' }
                    $roReason += '. Du kannst sie in Morpheus reparieren.'
                }
                elseif (-not $tempFehler) { $roReason = 'Der Datenordner unter ProgramData lässt sich nicht sichern: ' + $_.Exception.Message }
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
                        Start-Process -FilePath $psExe -ArgumentList $al
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
    Initialize-GuiServer -Root $Root -Port $Port -Token $token -BootCode $boot -SafetyPath $safetyPath -DefenderPath $defenderPath -SysinternalsPath $sysPath -WartungPath $wartungPath -WingetPath $wingetPath -DataRoot $dataRoot -ReadOnly:$roMode -ReadOnlyReason $roReason -DatenordnerZustand $datenordnerZustand -DatenordnerPfad $datenordnerPfad -TempSicher:$tempSicher
    $url = "http://127.0.0.1:$Port/#b=$boot"

    # 6. Fenster: Edge als App-Fenster mit eigenem Profil, sonst Standardbrowser
    if ($NoBrowser) {
        Write-Host "GUI läuft auf: $url" -ForegroundColor Green
        Write-Host '(Beenden: POST /api/shutdown oder Strg+C)'
    }
    else {
        $edgeExe = $null
        foreach ($c in @(
                (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Microsoft\Edge\Application\msedge.exe'))) {
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { $edgeExe = $c; break }
        }
        if ($edgeExe) {
            $profile = Join-Path $env:LOCALAPPDATA 'pc-check\edge'
            [void](New-Item -ItemType Directory -Path $profile -Force)
            # --start-maximized: bildschirmfüllend (ein App-Fenster merkt sich sonst die letzte Größe)
            # Die drei --disable-*-Schalter verhindern, dass Edge das Fenster im Hintergrund drosselt (Heartbeat bliebe sonst aus)
            Start-Process -FilePath $edgeExe -ArgumentList @("--app=$url", "--user-data-dir=`"$profile`"", '--start-maximized', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows')
            $edge = $profile
            Write-Host 'GUI läuft ... (Fenster schließen beendet)' -ForegroundColor Green
        }
        else {
            # Kein Standardbrowser aus dem Admin-Prozess: Sein Startbefehl steht in HKCU\Software\Classes und ist damit von
            # Benutzerprogrammen änderbar (2.3.3). Die Adresse enthält nur den Einmal-Code, nicht das Token.
            Write-Host 'Microsoft Edge wurde nicht gefunden. Bitte diese Adresse im Browser öffnen:' -ForegroundColor Yellow
            Write-Host $url -ForegroundColor Green
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
    if ($repTemp) {
        # Verknüpfungen werden nur selbst entfernt, nie betreten (MorpheusEntferneEintrag); Fehler nur protokollieren
        try {
            if (Test-Path -LiteralPath $repTemp) {
                if (Get-Command -Name MorpheusEntferneEintrag -CommandType Function -ErrorAction SilentlyContinue) { MorpheusEntferneEintrag (Get-Item -LiteralPath $repTemp -Force) }
            }
        }
        catch { try { Write-GuiLog ('Temp-Ordner der Reparatur nicht entfernt: ' + $_.Exception.Message) } catch { } }
    }
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
