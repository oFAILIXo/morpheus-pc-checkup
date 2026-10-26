#Requires -Version 5.1
# Pester-3.4-Tests fuer gui\lib\Server.ps1 (Offline-Countdown und statische Pruefungen). Startet keinen Server,
# ruft keine echten Defender-Funktionen auf. Ausfuehren: Invoke-Pester tests\Server.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Server.ps1')

$script:ServerText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\Server.ps1'), [Text.Encoding]::UTF8)
$script:TestDir = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-servertest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null

# Attrappe: zaehlt Aufrufe, kann scheitern
$script:OfflineCalls = 0
$script:OfflineFail = $false
function Start-MorpheusDefenderOffline {
    $script:OfflineCalls++
    if ($script:OfflineFail) { throw 'Attrappe: Start fehlgeschlagen' }
}

function Set-TestCountdown {
    param([double]$EndeInSek = 10, [double]$AbrufVorSek = 0)
    $script:Gui.Offline = @{ Status = 'countdown'; Ende = (Get-Date).AddSeconds($EndeInSek); LetzterAbruf = (Get-Date).AddSeconds(-$AbrufVorSek); Meldung = '' }
}

Describe 'Update-GuiOffline' {
    BeforeEach {
        $script:Gui = @{ DataRoot = $script:TestDir; Offline = $null }
        $script:OfflineCalls = 0
        $script:OfflineFail = $false
    }

    It 'ohne Countdown: Zustand keiner, nichts passiert' {
        Update-GuiOffline -EdgeCount 0
        $s = Get-GuiOfflineState
        $s.status | Should Be 'keiner'
        $s.rest | Should Be 0
        $script:OfflineCalls | Should Be 0
    }

    It 'laufender Countdown meldet rest > 0 und loest nicht aus' {
        Set-TestCountdown -EndeInSek 10
        Update-GuiOffline -EdgeCount 3
        $s = Get-GuiOfflineState
        $s.status | Should Be 'countdown'
        ($s.rest -gt 0) | Should Be $true
        $script:OfflineCalls | Should Be 0
    }

    It 'Ablauf loest genau einmal aus' {
        Set-TestCountdown -EndeInSek -1
        Update-GuiOffline -EdgeCount 3
        Update-GuiOffline -EdgeCount 3
        Update-GuiOffline -EdgeCount 3
        $script:OfflineCalls | Should Be 1
        (Get-GuiOfflineState).status | Should Be 'gestartet'
    }

    It 'fehlender Abruf seit mehr als 3 s bricht ab ohne Ausloesen' {
        Set-TestCountdown -EndeInSek -1 -AbrufVorSek 4
        Update-GuiOffline -EdgeCount 3
        (Get-GuiOfflineState).status | Should Be 'abgebrochen'
        $script:OfflineCalls | Should Be 0
    }

    It 'EdgeCount 0 bricht ab ohne Ausloesen' {
        Set-TestCountdown -EndeInSek -1
        Update-GuiOffline -EdgeCount 0
        (Get-GuiOfflineState).status | Should Be 'abgebrochen'
        $script:OfflineCalls | Should Be 0
    }

    It 'EdgeCount -1 (unbekannt) bricht nicht ab' {
        Set-TestCountdown -EndeInSek 10
        Update-GuiOffline -EdgeCount -1
        (Get-GuiOfflineState).status | Should Be 'countdown'
        $script:OfflineCalls | Should Be 0
    }

    It 'Fehler beim Start ergibt Status fehler mit Meldung' {
        $script:OfflineFail = $true
        Set-TestCountdown -EndeInSek -1
        Update-GuiOffline -EdgeCount 1
        $s = Get-GuiOfflineState
        $s.status | Should Be 'fehler'
        ($s.meldung -like '*Attrappe*') | Should Be $true
        $script:OfflineCalls | Should Be 1
    }

    It 'Zustandswechsel steht in gui.log' {
        Set-TestCountdown -EndeInSek -1 -AbrufVorSek 5
        Update-GuiOffline
        $log = [IO.File]::ReadAllText((Join-Path $script:TestDir 'state\gui.log'))
        ($log -like '*Offline-Scan: abgebrochen*') | Should Be $true
    }
}

Describe 'Server.ps1 (statisch)' {
    It 'Start-GuiJob sperrt speicher und defender im Nur-Lesen-Modus' {
        $script:ServerText | Should Match "ReadOnly -and \(\`$Art -in 'run', 'undo', 'scan', 'speicher', 'defender', 'sysinternals'\)"
    }
    It 'Start-GuiJob verlangt fuer defender eine Bestaetigung' {
        $script:ServerText | Should Match "if \(\`$Art -in 'run', 'undo', 'defender', 'sysinternals'\)"
    }
    It 'defender/run prueft die Art case-sensitiv' {
        $script:ServerText | Should Match "@\('signaturen', 'schnellscan'\) -cnotcontains \`$art"
    }
    It 'offline verlangt bestaetigt als Boolean true' {
        $script:ServerText | Should Match "\`$b -isnot \[bool\]"
    }
}

function Get-TestFehler {
    # Führt die Prüfung aus und gibt Status und Text der Fehlerantwort zurück ($null, wenn kein Fehler)
    param($Eintraege)
    try { [void](Test-GuiSpielordnerEintraege $Eintraege); return $null }
    catch { return [pscustomobject]@{ status = [int]$_.Exception.Data['status']; text = $_.Exception.Message } }
}
function New-TestEintrag { param([string]$Plattform, $Pfad) [pscustomobject]@{ plattform = $Plattform; pfad = $Pfad } }

Describe 'Test-GuiSpielordnerEintraege und Read-GuiSpielordner' {
    $wurzel = Join-Path $script:TestDir 'spiele'
    $bib = Join-Path $wurzel 'Bibliothek'
    $bib2 = Join-Path $wurzel 'Zweite'
    New-Item -ItemType Directory -Path $bib, $bib2 -Force | Out-Null
    $link = Join-Path $wurzel 'LinkOrdner'
    cmd /c mklink /J "$link" "$bib" | Out-Null

    It 'gültige Einträge werden normalisiert zurückgegeben' {
        $r = @(Test-GuiSpielordnerEintraege @((New-TestEintrag 'Steam' $bib), (New-TestEintrag 'Andere' ($bib2 + '\'))))
        $r.Count | Should Be 2
        $r[0].plattform | Should Be 'Steam'
        $r[1].pfad | Should Be $bib2
    }
    It 'leeres Array ist gültig, Nicht-Array und null nicht' {
        @(Test-GuiSpielordnerEintraege @()).Count | Should Be 0
        (Get-TestFehler $null).status | Should Be 400
        (Get-TestFehler 'text').status | Should Be 400
        (Get-TestFehler (New-TestEintrag 'Steam' $bib)).status | Should Be 400
    }
    It 'falsche Plattform (klein geschrieben) wird mit Nummer und Pfad abgelehnt' {
        $f = Get-TestFehler @((New-TestEintrag 'Steam' $bib), (New-TestEintrag 'steam' $bib2))
        $f.status | Should Be 400
        $f.text | Should Match "^Eintrag 2 (.*): Unbekannte Plattform"
    }
    It 'UNC-, relative und überlange Pfade werden abgelehnt' {
        (Get-TestFehler @(New-TestEintrag 'Steam' '\\server\share')).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' 'Spiele\x')).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' ('C:\' + ('a' * 300)))).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' 123)).status | Should Be 400
    }
    It 'Segmente . und .. sowie ungültige Zeichen werden abgelehnt' {
        (Get-TestFehler @(New-TestEintrag 'Steam' ($bib + '\..\Zweite'))).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' ($bib + '\.'))).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' ($bib + '\a*b'))).status | Should Be 400
        (Get-TestFehler @(New-TestEintrag 'Steam' ($bib + "`n"))).status | Should Be 400
    }
    It 'nicht vorhandener Ordner und Datei werden abgelehnt' {
        (Get-TestFehler @(New-TestEintrag 'GOG' (Join-Path $wurzel 'gibtsnicht'))).status | Should Be 400
        $datei = Join-Path $wurzel 'datei.txt'
        [IO.File]::WriteAllText($datei, 'x')
        (Get-TestFehler @(New-TestEintrag 'GOG' $datei)).status | Should Be 400
    }
    It 'Junction als Bibliothek wird abgelehnt' {
        $f = Get-TestFehler @(New-TestEintrag 'Xbox' $link)
        $f.status | Should Be 400
        ($f.text -like "Eintrag 1*Link*") | Should Be $true
    }
    It 'mehr als 50 Einträge werden abgelehnt, genau 50 nicht' {
        $e50 = @(1..50 | ForEach-Object { New-TestEintrag 'Steam' $bib })
        $e51 = @(1..51 | ForEach-Object { New-TestEintrag 'Steam' $bib })
        $e50.Count | Should Be 50
        $r = @(Test-GuiSpielordnerEintraege $e50)
        $r.Count | Should Be 1
        (Get-TestFehler $e51).status | Should Be 400
    }
    It 'doppelte Pfade (ohne Groß-/Kleinschreibung, mit und ohne Endbackslash) nur einmal, der erste gewinnt' {
        $r = @(Test-GuiSpielordnerEintraege @((New-TestEintrag 'Epic' $bib), (New-TestEintrag 'GOG' ($bib.ToUpper() + '\')), (New-TestEintrag 'GOG' $bib2)))
        $r.Count | Should Be 2
        $r[0].plattform | Should Be 'Epic'
    }
    It 'Read-GuiSpielordner: fehlend/kaputt leer, sonst bereinigt, immer als Array serialisierbar' {
        @(Read-GuiSpielordner (Join-Path $script:TestDir 'nix.json')).Count | Should Be 0
        $kaputt = Join-Path $script:TestDir 'kaputt.json'
        [IO.File]::WriteAllText($kaputt, '[{ nope')
        @(Read-GuiSpielordner $kaputt).Count | Should Be 0
        $d = Join-Path $script:TestDir 'so.json'
        $bibJ = $bib.Replace('\', '\\')
        [IO.File]::WriteAllText($d, '[{"plattform":"Steam","pfad":"' + $bibJ + '"},{"plattform":"steam","pfad":"' + $bibJ + '"},{"plattform":"Epic","pfad":"\\\\s\\x"}]')
        $r = @(Read-GuiSpielordner $d)
        $r.Count | Should Be 1
        (ConvertTo-Json -InputObject @($r) -Compress) | Should Match '^\[\{"plattform":"Steam"'
        (ConvertTo-Json -InputObject @(Read-GuiSpielordner $kaputt) -Compress) | Should Be '[]'
    }
    It 'Speichern: Save-GuiTextAtomic schreibt ein Array auch bei einem Eintrag' {
        $p = Join-Path $script:TestDir 'state\spielordner.json'
        $r = @(Test-GuiSpielordnerEintraege @((New-TestEintrag 'Steam' $bib)))
        Save-GuiTextAtomic $p (ConvertTo-Json -InputObject $r -Depth 4 -Compress)
        [IO.File]::ReadAllText($p) | Should Match '^\[\{"plattform":"Steam","pfad":".*"\}\]$'
        @(Read-GuiSpielordner $p).Count | Should Be 1
    }
}

Describe 'Route /api/spielordner (statisch)' {
    $start = $script:ServerText.IndexOf("if (`$Path -eq '/api/spielordner')")
    $ende = $script:ServerText.IndexOf("if (`$Path -eq '/api/defender')")
    $route = ''
    if (($start -ge 0) -and ($ende -gt $start)) { $route = $script:ServerText.Substring($start, $ende - $start) }
    It 'Route ist vorhanden' { ($route.Length -gt 0) | Should Be $true }
    It 'POST ist im Nur-Lesen-Modus gesperrt (Assert-GuiWritable)' { $route | Should Match 'Assert-GuiWritable' }
    It 'POST nutzt die Prüffunktion und speichert atomar' {
        $route | Should Match 'Test-GuiSpielordnerEintraege'
        $route | Should Match 'Save-GuiTextAtomic'
    }
    It 'Falsche Methode ergibt 405, GET liest über Read-GuiSpielordner' {
        $route | Should Match "405 'Methode nicht erlaubt\.'"
        $route | Should Match 'Read-GuiSpielordner'
    }
    It 'Log-Zeile ohne Pfade' {
        $route | Should Match 'Spiele-Ordner gespeichert \(\{0\} Einträge\)'
    }
    It 'Job speicher liest die Datei und übergibt -Manuell' {
        $script:ServerText | Should Match 'Read-MorpheusSpielordner -Datei \(Join-Path \$DataRoot ''state\\spielordner\.json''\)'
        $script:ServerText | Should Match 'Get-MorpheusSpeicher -Manuell \$manuell'
    }
}

# --- Sysinternals-Routen (v2.3, Abschnitt 15.6): Attrappen, nichts wird geladen, kein echter Job ---
$script:SysCalls = @{ Confirm = 0; Job = 0; Zustimmung = 0; Install = 0; Remove = 0 }
$script:SysConfirmAntwort = $true
$script:SysConfirmText = $null
$script:SysJobArgs = $null
function Confirm-GuiElevated { param([string]$Text) $script:SysCalls.Confirm++; $script:SysConfirmText = $Text; return $script:SysConfirmAntwort }
function Start-Job { param($ScriptBlock, $ArgumentList) $script:SysCalls.Job++; $script:SysJobArgs = $ArgumentList; return [pscustomobject]@{ State = 'Running'; ChildJobs = @() } }
function Get-MorpheusSysStand { param($DataRoot) [ordered]@{ zustimmung = [ordered]@{ akzeptiert = $false; zeit = $null; benutzer = $null }; werkzeuge = @(); ordner = (Join-Path $DataRoot 'tools'); lizenzUrl = 'https://example.invalid/lizenz' } }
function Set-MorpheusSysZustimmung { param($DataRoot, [bool]$Akzeptiert) $script:SysCalls.Zustimmung++ }
function Install-MorpheusSysWerkzeuge { param($DataRoot) $script:SysCalls.Install++ }
function Remove-MorpheusSysWerkzeuge { param($DataRoot) $script:SysCalls.Remove++; Get-MorpheusSysStand -DataRoot $DataRoot }
function Get-MorpheusSysEula { param($DataRoot, $Name) if ($Name -ceq 'sigcheck') { return $null }; return 'Lizenztext ' + $Name }

function Invoke-TestRoute {
    param([string]$Method, [string]$Path, [string]$Json, $Query = @{})
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Json)
    $req = [pscustomobject]@{
        Headers = @{ 'X-PcCheck-Token' = 'testtoken' }; ContentType = 'application/json'; HasEntityBody = ($bytes.Length -gt 0)
        ContentLength64 = [long]$bytes.Length; InputStream = (New-Object IO.MemoryStream (, $bytes)); QueryString = $Query
    }
    $out = New-Object IO.MemoryStream
    $res = [pscustomobject]@{ StatusCode = 0; ContentType = ''; Headers = (New-Object Net.WebHeaderCollection); ContentLength64 = [long]0; OutputStream = $out }
    $script:Gui.Status = 0
    $status = 0; $obj = $null; $err = $null
    try {
        Invoke-GuiRoute $req $res $Method $Path
        $status = [int]$script:Gui.Status
        if ($out.Length -gt 0) { $obj = [Text.Encoding]::UTF8.GetString($out.ToArray()) | ConvertFrom-Json }
    }
    catch { $status = [int]$_.Exception.Data['status']; $err = $_.Exception.Message }
    return [pscustomobject]@{ status = $status; json = $obj; error = $err }
}

Describe 'Routen /api/sysinternals* (mit Attrappen)' {
    BeforeEach {
        $script:Gui = @{ Root = $script:TestDir; DataRoot = $script:TestDir; ReadOnly = $false; ReadOnlyReason = 'test'; Token = 'testtoken'
            SysinternalsPath = 'C:\nicht\vorhanden\Sysinternals.ps1'; Jobs = @{}; LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 0 }
        $script:SysCalls = @{ Confirm = 0; Job = 0; Zustimmung = 0; Install = 0; Remove = 0 }
        $script:SysConfirmAntwort = $true
        $script:SysConfirmText = $null
        $script:SysJobArgs = $null
    }

    It 'GET /api/sysinternals liefert Stand und laufend' {
        $r = Invoke-TestRoute 'GET' '/api/sysinternals'
        $r.status | Should Be 200
        $r.json.zustimmung.akzeptiert | Should Be $false
        ($null -eq $r.json.laufend) | Should Be $true
        ($r.json.PSObject.Properties.Name -contains 'lizenzUrl') | Should Be $true
    }
    It 'GET /api/sysinternals nennt die jobId eines laufenden Jobs' {
        $script:Gui.Jobs['abc12345'] = @{ Id = 'abc12345'; Art = 'sysinternals'; Status = 'running' }
        (Invoke-TestRoute 'GET' '/api/sysinternals').json.laufend | Should Be 'abc12345'
    }
    It 'install ohne eulaAkzeptiert: 400, keine Bestaetigung, kein Job' {
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{}'
        $r.status | Should Be 400
        $r.error | Should Be 'Bitte zuerst die Lizenzbedingungen annehmen.'
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    foreach ($falsch in '"true"', '1', 'false', 'null', '"ja"') {
        It "install mit eulaAkzeptiert = $falsch : 400" {
            $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' ('{"eulaAkzeptiert":' + $falsch + '}')
            $r.status | Should Be 400
            $script:SysCalls.Confirm | Should Be 0
            $script:SysCalls.Job | Should Be 0
        }
    }
    It 'install im Nur-Lesen-Modus: 403' {
        $script:Gui.ReadOnly = $true
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":true}'
        $r.status | Should Be 403
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'install im Nur-Lesen-Modus mit ungueltigem Body: 403 (Schreibschutz zuerst)' {
        $script:Gui.ReadOnly = $true
        (Invoke-TestRoute 'POST' '/api/sysinternals/install' '{}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":"ja"}').status | Should Be 403
        $script:SysCalls.Job | Should Be 0
    }
    It 'install: laufender Scan ergibt 409 ohne Bestaetigung' {
        $script:Gui.Jobs['scan0001'] = @{ Id = 'scan0001'; Art = 'scan'; Status = 'running' }
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":true}'
        $r.status | Should Be 409
        $r.error | Should Match 'Scans'
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'entfernen: laufender Scan ergibt 409' {
        $script:Gui.Jobs['scan0001'] = @{ Id = 'scan0001'; Art = 'scan'; Status = 'running' }
        (Invoke-TestRoute 'POST' '/api/sysinternals/entfernen' '{}').status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Remove | Should Be 0
    }
    It 'scan: laufender Sysinternals-Job ergibt 409, kein Scan-Job' {
        $script:Gui.Jobs['abc12345'] = @{ Id = 'abc12345'; Art = 'sysinternals'; Status = 'running' }
        $r = Invoke-TestRoute 'POST' '/api/scan' '{}'
        $r.status | Should Be 409
        $script:SysCalls.Job | Should Be 0
    }
    It 'install: abgelehnte Bestaetigung ergibt 403, keinen Job, keine Zustimmung' {
        $script:SysConfirmAntwort = $false
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":true}'
        $r.status | Should Be 403
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Job | Should Be 0
        $script:SysCalls.Zustimmung | Should Be 0
        $script:SysCalls.Install | Should Be 0
        $script:Gui.Jobs.Count | Should Be 0
    }
    It 'install: laufender Job ergibt 409 ohne Bestaetigung' {
        $script:Gui.Jobs['abc12345'] = @{ Id = 'abc12345'; Art = 'sysinternals'; Status = 'running' }
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":true}'
        $r.status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'install: Erfolg startet genau einen Job nach der Bestaetigung (Text mit echtem Ordner)' {
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/install' '{"eulaAkzeptiert":true}'
        $r.status | Should Be 200
        ($r.json.jobId.Length -gt 0) | Should Be $true
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Job | Should Be 1
        $script:SysCalls.Zustimmung | Should Be 0   # wird erst im Job gespeichert
        ($script:SysConfirmText -like ('*' + (Join-Path $script:TestDir 'tools') + '*')) | Should Be $true
        ($script:SysConfirmText -like "*'Nein'*") | Should Be $true
        $script:Gui.Jobs.Count | Should Be 1
        $script:Gui.Jobs[$r.json.jobId].Art | Should Be 'sysinternals'
        $script:SysJobArgs[2] | Should Be $script:TestDir
    }
    It 'entfernen im Nur-Lesen-Modus: 403' {
        $script:Gui.ReadOnly = $true
        (Invoke-TestRoute 'POST' '/api/sysinternals/entfernen' '{}').status | Should Be 403
        $script:SysCalls.Remove | Should Be 0
    }
    It 'entfernen: laufender Job ergibt 409' {
        $script:Gui.Jobs['abc12345'] = @{ Id = 'abc12345'; Art = 'sysinternals'; Status = 'running' }
        (Invoke-TestRoute 'POST' '/api/sysinternals/entfernen' '{}').status | Should Be 409
        $script:SysCalls.Remove | Should Be 0
    }
    It 'entfernen: abgelehnt ergibt 403 und entfernt nichts' {
        $script:SysConfirmAntwort = $false
        (Invoke-TestRoute 'POST' '/api/sysinternals/entfernen' '{}').status | Should Be 403
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Remove | Should Be 0
    }
    It 'entfernen: bestaetigt entfernt und liefert den Stand' {
        $vorher = $script:Gui.LastHeartbeat
        $r = Invoke-TestRoute 'POST' '/api/sysinternals/entfernen' '{}'
        $r.status | Should Be 200
        $script:SysCalls.Remove | Should Be 1
        ($r.json.PSObject.Properties.Name -contains 'werkzeuge') | Should Be $true
        ($script:Gui.LastHeartbeat -gt $vorher) | Should Be $true
    }
    It 'eula mit ungueltigem Namen: 400' {
        foreach ($n in 'AUTORUNSC', 'foo', '', '..\x') {
            (Invoke-TestRoute 'GET' '/api/sysinternals/eula' '' @{ name = $n }).status | Should Be 400
        }
        (Invoke-TestRoute 'GET' '/api/sysinternals/eula' '' @{}).status | Should Be 400
    }
    It 'eula liefert Text bzw. null' {
        $a = Invoke-TestRoute 'GET' '/api/sysinternals/eula' '' @{ name = 'autorunsc' }
        $a.status | Should Be 200
        $a.json.name | Should Be 'autorunsc'
        $a.json.text | Should Be 'Lizenztext autorunsc'
        $s = Invoke-TestRoute 'GET' '/api/sysinternals/eula' '' @{ name = 'sigcheck' }
        $s.status | Should Be 200
        ($null -eq $s.json.text) | Should Be $true
    }
    It 'Start-GuiJob sysinternals im Nur-Lesen-Modus: 403, kein Job' {
        $script:Gui.ReadOnly = $true
        $code = 0
        try { [void](Start-GuiJob 'sysinternals' @('a', 'b', 'c') $false 'Text') } catch { $code = [int]$_.Exception.Data['status'] }
        $code | Should Be 403
        $script:SysCalls.Job | Should Be 0
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'Start-GuiJob sysinternals ohne Bestaetigungstext: 500' {
        $code = 0
        try { [void](Start-GuiJob 'sysinternals' @('a', 'b', 'c') $false) } catch { $code = [int]$_.Exception.Data['status'] }
        $code | Should Be 500
        $script:SysCalls.Job | Should Be 0
    }
    It 'scan: skipSysinternals wird als -SkipSysinternals durchgereicht' {
        $r = Invoke-TestRoute 'POST' '/api/scan' '{"skipSysinternals":true}'
        $r.status | Should Be 200
        ($script:SysJobArgs[1] -contains '-SkipSysinternals') | Should Be $true
    }
    It 'scan: ohne skipSysinternals kein Schalter, falscher Typ ergibt 400' {
        $r = Invoke-TestRoute 'POST' '/api/scan' '{}'
        $r.status | Should Be 200
        ($script:SysJobArgs[1] -contains '-SkipSysinternals') | Should Be $false
        (Invoke-TestRoute 'POST' '/api/scan' '{"skipSysinternals":"true"}').status | Should Be 400
    }
    It 'Job-Script sysinternals speichert die Zustimmung erst im Job' {
        $s = $script:GuiJobScripts['sysinternals'].ToString()
        $s | Should Match 'Set-MorpheusSysZustimmung -DataRoot \$DataRoot -Akzeptiert \$true'
        ($s.IndexOf('Set-MorpheusSysZustimmung') -lt $s.IndexOf('Install-MorpheusSysWerkzeuge')) | Should Be $true
    }
}

# --- Akzeptanz- und Defender-Datei-Routen (v2.3.1, Abschnitt 16.4): Attrappen, nichts wird geschrieben oder gescannt ---
$script:AkzRegeln = @()
$script:AkzHist = @()
$script:AkzThrow = $null
$script:AkzTestFehler = $null
$script:AkzRemoved = @()
function Read-MorpheusAkzeptanz { param($Datei) return @($script:AkzRegeln) }
function Add-MorpheusAkzeptanz { param($Datei, $Regel) if ($script:AkzThrow) { throw $script:AkzThrow }; $script:AkzRegeln += , $Regel; return $Regel }
function Remove-MorpheusAkzeptanz { param($Datei, $Id) if ($Id -ceq 'aaaaaaaa') { throw 'Regel nicht gefunden.' }; $script:AkzRemoved += $Id; return [pscustomobject]@{ id = $Id } }
function Test-MorpheusAkzeptanzRegel { param($Datei, $Regel) return $script:AkzTestFehler }
function Get-MorpheusAkzeptanzRegel { param($Datei, $Id) if ($Id -ceq 'aaaaaaaa') { return $null }; return [pscustomobject]@{ id = $Id; check = 'Meine Prüfung'; match = '^x$'; reason = "Grund`nzwei"; datei = $null } }
function Add-MorpheusAkzeptanzHistorie { param($Datei, $Art, $Regel, $Benutzer) $script:AkzHist += , $Art }
function Get-MorpheusDefenderStand { }
function Invoke-MorpheusDefenderAktion { param($Art, $Pfad) }

Describe 'Routen /api/akzeptanz* und /api/defender/datei (mit Attrappen)' {
    BeforeEach {
        $script:Sys32 = Join-Path $script:TestDir 'sys32'
        New-Item -ItemType Directory -Path $script:Sys32, (Join-Path $script:TestDir 'reports') -Force | Out-Null
        $script:Datei = Join-Path $script:Sys32 'treiber.sys'
        [IO.File]::WriteAllText($script:Datei, 'inhalt-a')
        $script:Hash = (Get-FileHash -LiteralPath $script:Datei -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:GuiSystem32Root = $script:Sys32
        $script:BName = 'pc-check_2026-10-26_1200.json'
        $bericht = [ordered]@{
            Meta = [ordered]@{ Version = '2.3.1' }
            Findings = @(
                [ordered]@{ Check = 'A*[x]'; Status = 'WARN'; OriginalStatus = ''; Value = 'a.b+(c)' },
                [ordered]@{ Check = 'Ok-Pruefung'; Status = 'OK'; OriginalStatus = ''; Value = 'gut' },
                [ordered]@{ Check = 'Schon'; Status = 'ACK'; OriginalStatus = 'CRIT'; Value = 'x' },
                [ordered]@{ Check = 'Systemdateien: Signaturen (Sigcheck)'; Status = 'WARN'; OriginalStatus = ''; Value = '1 Datei' })
            Data = [ordered]@{ 'Unsignierte Systemdateien (Sigcheck)' = @([ordered]@{ Pfad = $script:Datei; Sha256 = $script:Hash }) }
        }
        [IO.File]::WriteAllText((Join-Path $script:TestDir ('reports\' + $script:BName)), (ConvertTo-Json -InputObject $bericht -Depth 6), (New-Object Text.UTF8Encoding $true))
        $script:Gui = @{ Root = $script:TestDir; DataRoot = $script:TestDir; ReadOnly = $false; ReadOnlyReason = 'test'; Token = 'testtoken'
            DefenderPath = 'C:\nicht\vorhanden\Defender.ps1'; Jobs = @{}; Offline = $null; LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 0 }
        $script:SysCalls = @{ Confirm = 0; Job = 0; Zustimmung = 0; Install = 0; Remove = 0 }
        $script:SysConfirmAntwort = $true
        $script:SysConfirmText = $null
        $script:SysJobArgs = $null
        $script:AkzRegeln = @(); $script:AkzHist = @(); $script:AkzThrow = $null; $script:AkzRemoved = @(); $script:AkzTestFehler = $null
    }
    AfterEach { $script:GuiSystem32Root = $null }

    It 'GET /api/akzeptanz liefert regeln, datei und bearbeitbar' {
        $r = Invoke-TestRoute 'GET' '/api/akzeptanz'
        $r.status | Should Be 200
        $r.json.bearbeitbar | Should Be $true
        $r.json.datei | Should Match 'accepted\.psd1$'
    }
    It 'Nur-Lesen: alle POST-Routen 403, nichts bestaetigt' {
        $script:Gui.ReadOnly = $true
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"A*[x]","begruendung":"Grund"}'
        (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/akzeptanz/abcdef12/entfernen' '{}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/defender/datei' '{}').status | Should Be 403
        $script:SysCalls.Confirm | Should Be 0
        $script:AkzRegeln.Count | Should Be 0
    }
    It 'befund abgelehnt: 403, nichts geschrieben' {
        $script:SysConfirmAntwort = $false
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"A*[x]","begruendung":"Grund"}'
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 403
        $r.error | Should Match 'Es wurde nichts geändert\.'
        $script:AkzRegeln.Count | Should Be 0
        $script:AkzHist.Count | Should Be 0
    }
    It 'befund: Wildcard- und Regex-Zeichen werden escaped, genau eine Regel' {
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"A*[x]","begruendung":"Grund","bis":null}'
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 200
        $script:AkzRegeln.Count | Should Be 1
        $script:AkzRegeln[0].Check | Should Be ([Management.Automation.WildcardPattern]::Escape('A*[x]'))
        $script:AkzRegeln[0].Check | Should Not Be 'A*[x]'
        $script:AkzRegeln[0].Match | Should Be ('^' + [regex]::Escape('a.b+(c)') + '$')
        $script:AkzRegeln[0].ContainsKey('Until') | Should Be $false
        $script:AkzHist[0] | Should Be 'akzeptiert'
        $script:SysCalls.Confirm | Should Be 1
    }
    It 'befund: ACK-Befund mit OriginalStatus CRIT ist erlaubt, Bis wird uebernommen' {
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"Schon","begruendung":"Grund","bis":"2027-01-01"}'
        (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 200
        $script:AkzRegeln[0].Until | Should Be '2027-01-01'
    }
    It 'befund nicht im Bericht, mit Status OK oder falscher Schreibweise: 404' {
        foreach ($c in 'Gibt-es-nicht', 'Ok-Pruefung', 'a*[x]') {
            $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"' + $c + '","begruendung":"Grund"}'
            (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 404
        }
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'Sigcheck-Pruefung als befund: 400' {
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"Systemdateien: Signaturen (Sigcheck)","begruendung":"Grund"}'
        (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 400
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'ungueltige Felder: 400 (art, begruendung, bis, check, Berichtsname)' {
        (Invoke-TestRoute 'POST' '/api/akzeptanz' '{"art":"x"}').status | Should Be 400
        $n = $script:BName
        (Invoke-TestRoute 'POST' '/api/akzeptanz' ('{"art":"befund","bericht":"' + $n + '","check":"Schon","begruendung":5}')).status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/akzeptanz' ('{"art":"befund","bericht":"' + $n + '","check":"Schon","begruendung":"G","bis":5}')).status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/akzeptanz' ('{"art":"befund","bericht":"' + $n + '","check":5,"begruendung":"G"}')).status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/akzeptanz' '{"art":"befund","bericht":"..\\x\\pc-check_2026-10-26_1200.json","check":"Schon","begruendung":"G"}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/akzeptanz' '{"art":"befund","bericht":"reports/pc-check_2026-10-26_1200.json","check":"Schon","begruendung":"G"}').status | Should Be 400
        $script:AkzRegeln.Count | Should Be 0
    }
    It 'Pruefungsfehler (Begruendung ungueltig): 400 mit Meldung, ohne Dialog' {
        $script:AkzTestFehler = 'Die Begründung ist zu kurz.'
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"Schon","begruendung":"x"}'
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 400
        $r.error | Should Be 'Die Begründung ist zu kurz.'
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'bereits akzeptiert: 409 ohne Dialog' {
        $script:AkzTestFehler = 'Das ist bereits akzeptiert.'
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"Schon","begruendung":"Grund"}'
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'Schreibfehler nach dem Dialog: 500' {
        $script:AkzThrow = 'Datei gesperrt'
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"Schon","begruendung":"Grund"}'
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 500
        $r.error | Should Be 'Die Akzeptanzliste konnte nicht gespeichert werden: Datei gesperrt'
        $script:SysCalls.Confirm | Should Be 1
    }
    It 'Dialogtext: Zeilenumbrueche der Begruendung werden zu Leerzeichen, Befundtext wird gezeigt' {
        $b = '{"art":"befund","bericht":"' + $script:BName + '","check":"A*[x]","begruendung":"a\nb\u202ec"}'
        (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 200
        $script:SysConfirmText | Should Match 'Begründung: a b c\n'
        $script:SysConfirmText | Should Match 'Befund: a\.b\+\(c\)'
        $script:SysConfirmText | Should Match 'Gilt nur, solange der Befund genau so lautet\.'
    }
    It 'Format-GuiDialogWert ersetzt Steuerzeichen und kuerzt' {
        Format-GuiDialogWert "a`r`nb`tc" 50 | Should Be 'a  b c'
        (Format-GuiDialogWert ('x' * 10) 4) | Should Be ('xxxx' + [char]0x2026)
    }
    It 'datei: Erfolg schreibt genau eine Regel mit dem Hash aus dem Bericht' {
        $b = @{ art = 'datei'; bericht = $script:BName; pfad = $script:Datei; begruendung = 'Alter Treiber' } | ConvertTo-Json -Compress
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 200
        $script:AkzRegeln.Count | Should Be 1
        $script:AkzRegeln[0].Check | Should Be 'Systemdateien: Signaturen (Sigcheck)'
        $script:AkzRegeln[0].Sha256 | Should Be $script:Hash
        $script:AkzRegeln[0].Datei | Should Be $script:Datei
        $script:SysConfirmText | Should Match 'treiber\.sys'
    }
    It 'datei: Pfad ausserhalb System32 oder mit .. : 400' {
        $aussen = Join-Path $script:TestDir 'andere.sys'
        [IO.File]::WriteAllText($aussen, 'x')
        foreach ($p in $aussen, ($script:Sys32 + '\..\andere.sys'), ($script:Sys32 + '\..'), 'treiber.sys') {
            $b = @{ art = 'datei'; bericht = $script:BName; pfad = $p; begruendung = 'Grund' } | ConvertTo-Json -Compress
            (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 400
        }
        $script:AkzRegeln.Count | Should Be 0
    }
    It 'datei: nicht im Bericht: 404' {
        $zwei = Join-Path $script:Sys32 'zwei.sys'
        [IO.File]::WriteAllText($zwei, 'x')
        $b = @{ art = 'datei'; bericht = $script:BName; pfad = $zwei; begruendung = 'Grund' } | ConvertTo-Json -Compress
        (Invoke-TestRoute 'POST' '/api/akzeptanz' $b).status | Should Be 404
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'datei: falscher Hash (Datei geaendert): 409' {
        [IO.File]::WriteAllText($script:Datei, 'inhalt-b')
        $b = @{ art = 'datei'; bericht = $script:BName; pfad = $script:Datei; begruendung = 'Grund' } | ConvertTo-Json -Compress
        $r = Invoke-TestRoute 'POST' '/api/akzeptanz' $b
        $r.status | Should Be 409
        $r.error | Should Be 'Die Datei hat sich seit dem Scan geändert. Bitte neu scannen.'
        $script:AkzRegeln.Count | Should Be 0
    }
    It 'entfernen: ungueltige Id 400, unbekannte Id 404 ohne Dialog, abgelehnt 403, Erfolg' {
        foreach ($i in 'xyz', 'ABCDEF12', 'abcdef1', 'habcdef123456') {
            (Invoke-TestRoute 'POST' ('/api/akzeptanz/' + $i + '/entfernen') '{}').status | Should Be 400
        }
        $script:SysCalls.Confirm | Should Be 0
        (Invoke-TestRoute 'POST' '/api/akzeptanz/aaaaaaaa/entfernen' '{}').status | Should Be 404
        $script:SysCalls.Confirm | Should Be 0
        $script:SysConfirmAntwort = $false
        (Invoke-TestRoute 'POST' '/api/akzeptanz/abcdef12/entfernen' '{}').status | Should Be 403
        $script:AkzRemoved.Count | Should Be 0
        $script:SysConfirmAntwort = $true
        (Invoke-TestRoute 'POST' '/api/akzeptanz/habcdef1234/entfernen' '{}').status | Should Be 200
        $script:AkzRemoved[0] | Should Be 'habcdef1234'
        $script:AkzHist[-1] | Should Be 'zurueckgenommen'
        $script:SysConfirmText | Should Match 'Meine Prüfung'
        $script:SysConfirmText | Should Match 'Befundmuster: \^x\$'
        $script:SysConfirmText | Should Match 'Begründung: Grund zwei'
    }
    It 'defender/datei: Erfolg startet Job datei mit Pfad, Text nennt die Datei' {
        $b = @{ bericht = $script:BName; pfad = $script:Datei } | ConvertTo-Json -Compress
        $r = Invoke-TestRoute 'POST' '/api/defender/datei' $b
        $r.status | Should Be 200
        $script:SysCalls.Job | Should Be 1
        $script:SysJobArgs[2] | Should Be 'datei'
        $script:SysJobArgs[3] | Should Be $script:Datei
        $script:SysConfirmText | Should Match 'treiber\.sys'
    }
    It 'defender/datei: laufender Defender-Job 409, abgelehnt 403, Berichtname mit Pfadanteil 400' {
        $b = @{ bericht = $script:BName; pfad = $script:Datei } | ConvertTo-Json -Compress
        $script:Gui.Jobs['abc12345'] = @{ Id = 'abc12345'; Art = 'defender'; Status = 'running' }
        (Invoke-TestRoute 'POST' '/api/defender/datei' $b).status | Should Be 409
        $script:Gui.Jobs = @{}
        $script:SysConfirmAntwort = $false
        (Invoke-TestRoute 'POST' '/api/defender/datei' $b).status | Should Be 403
        $script:SysCalls.Job | Should Be 0
        $b2 = @{ bericht = ('..\' + $script:BName); pfad = $script:Datei } | ConvertTo-Json -Compress
        (Invoke-TestRoute 'POST' '/api/defender/datei' $b2).status | Should Be 400
    }
    It 'Job-Script defender nimmt Pfad entgegen' {
        $script:GuiJobScripts['defender'].ToString() | Should Match 'param\(\$Root, \$DefenderPath, \$Art, \$Pfad\)'
    }
}

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
