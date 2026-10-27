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
        $script:ServerText | Should Match "ReadOnly -and \(\`$Art -in 'run', 'undo', 'scan', 'speicher', 'defender', 'sysinternals', 'wartung', 'updatesuche'\)"
    }
    It 'Start-GuiJob verlangt fuer defender eine Bestaetigung' {
        $script:ServerText | Should Match "if \(\`$Art -in 'run', 'undo', 'defender', 'sysinternals', 'wartung'\)"
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
    $status = 0; $obj = $null; $err = $null; $raw = $null
    try {
        Invoke-GuiRoute $req $res $Method $Path
        $status = [int]$script:Gui.Status
        if ($out.Length -gt 0) {
            $raw = [Text.Encoding]::UTF8.GetString($out.ToArray())
            try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null }   # z. B. HTML-Berichte
        }
    }
    catch { $status = [int]$_.Exception.Data['status']; $err = $_.Exception.Message }
    return [pscustomobject]@{ status = $status; json = $obj; error = $err; raw = $raw }
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
    It 'Format-GuiDialogWert entfernt NEL, Richtungsmarken und Nullbreite-Zeichen' {
        $t = 'a' + [char]0x0085 + 'b' + [char]0x200F + 'c' + [char]0x061C + 'd' + [char]0x200B + 'e' + [char]0xFEFF + 'f'
        Format-GuiDialogWert $t 50 | Should Be 'a b c d e f'
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

# --- Wartung & Reparatur, Updates (v2.4, Abschnitt 18.5): Attrappen, keine echten Werkzeuge, kein winget ---
$script:WzKatalog = @(
    [pscustomobject]@{ id = 'dism.checkhealth'; klasse = 'diagnose'; titel = 'DISM: CheckHealth'; erklaerung = 'Prueft schnell.'; befehl = 'Dism.exe /Online /Cleanup-Image /CheckHealth'; abbruch = 'sofort'; parameter = $null }
    [pscustomobject]@{ id = 'dism.restorehealth'; klasse = 'reparatur'; titel = 'DISM: Komponentenspeicher reparieren'; erklaerung = 'Repariert.'; befehl = 'Dism.exe /Online /Cleanup-Image /RestoreHealth'; abbruch = 'nein'; parameter = $null }
    [pscustomobject]@{ id = 'sfc.scannow'; klasse = 'reparatur'; titel = 'SFC'; erklaerung = 'Repariert Systemdateien.'; befehl = 'sfc.exe /scannow'; abbruch = 'nein'; parameter = $null }
    [pscustomobject]@{ id = 'dns.flush'; klasse = 'wartung'; titel = 'DNS-Cache leeren'; erklaerung = 'Leert den DNS-Cache.'; befehl = 'ipconfig.exe /flushdns'; abbruch = 'nein'; parameter = $null }
    [pscustomobject]@{ id = 'chkdsk.scan'; klasse = 'diagnose'; titel = 'chkdsk'; erklaerung = 'Prueft.'; befehl = 'chkdsk.exe <LW> /scan'; abbruch = 'sofort'; parameter = 'laufwerk' }
    [pscustomobject]@{ id = 'trim'; klasse = 'wartung'; titel = 'ReTrim'; erklaerung = 'Trim.'; befehl = 'defrag.exe <LW> /L'; abbruch = 'sofort'; parameter = 'ssd' }
    [pscustomobject]@{ id = 'winget.upgrade'; klasse = 'reparatur'; titel = 'Programme aktualisieren'; erklaerung = 'winget.'; befehl = 'winget upgrade --id <Paket-Id>'; abbruch = 'nach-paket'; parameter = 'ids' }
    [pscustomobject]@{ id = 'perfmon.rel'; klasse = 'diagnose'; titel = 'Zuverlaessigkeitsverlauf'; erklaerung = 'Zeigt an.'; befehl = 'perfmon /rel'; abbruch = 'nein'; parameter = $null }
)
$script:LwAufrufe = 0
$script:ZuverlThrow = $false
$script:TestJournal = @()
function Get-MorpheusWartungWerkzeuge { return @($script:WzKatalog) }
function Get-MorpheusWartungLaufwerke {
    $script:LwAufrufe++
    return @([pscustomobject]@{ laufwerk = 'C:'; bezeichnung = 'System'; ssd = $true }, [pscustomobject]@{ laufwerk = 'D:'; bezeichnung = 'Daten'; ssd = $false })
}
function Test-MorpheusWartungAuftrag {
    param($Werkzeug, $Laufwerk, $Laufwerke)
    $w = @($script:WzKatalog) | Where-Object { $_.id -ceq $Werkzeug } | Select-Object -First 1
    if ((-not $w) -or (@('winget.upgrade', 'perfmon.rel') -ccontains $Werkzeug)) { return 'Unbekanntes Werkzeug.' }
    if (@('laufwerk', 'ssd') -ccontains [string]$w.parameter) {
        if (-not $Laufwerk) { return 'Laufwerk fehlt.' }
        $l = @($Laufwerke) | Where-Object { $_.laufwerk -ceq $Laufwerk } | Select-Object -First 1
        if (-not $l) { return 'Unbekanntes Laufwerk.' }
        if (([string]$w.parameter -ceq 'ssd') -and ($l.ssd -ne $true)) { return 'Das ist keine SSD.' }
    }
    elseif ($PSBoundParameters.ContainsKey('Laufwerk')) { return 'Dieses Werkzeug hat kein Laufwerk.' }
    return $null
}
function Get-MorpheusWartungBerichte { param($DataRoot) return @([pscustomobject]@{ name = 'morpheus-energy_2026-10-26_153012.html'; art = 'energy'; titel = 'Energiebericht'; zeit = '2026-10-26T15:30:12' }) }
function Start-MorpheusZuverlaessigkeit { if ($script:ZuverlThrow) { throw 'Explorer nicht startbar' }; return [pscustomobject]@{ ok = $true; meldung = 'Geoeffnet.' } }
function Get-MorpheusWingetUpdates { }
function Get-PcCheckCatalog { param($Root) return @() }
function Invoke-PcCheckChange { param($Root, $DataRoot, $Ids, $Variante) }
function Undo-PcCheckChange { param($Root, $DataRoot, $EntryId, [switch]$Force) }
function Get-PcCheckJournal { param($Root, $DataRoot) return @($script:TestJournal) }
# Update-GuiJobs ruft Receive-Job/Remove-Job auf; in diesem Test gibt es nur Attrappen-Jobs mit .Out
function Receive-Job { param($Job, $ErrorAction, $WarningAction, $InformationAction) return @($Job.Out) }
# Gemeinsame Undo-Sperre (18.10): die echte Funktion aus Safety.ps1 (ohne den Rest der Datei zu laden)
$script:SafetyAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\gui\lib\Safety.ps1'), [ref]$null, [ref]$null)
$script:VorRepFn = $script:SafetyAst.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Test-PcCheckVorReparatur') }, $true)
. ([scriptblock]::Create($script:VorRepFn.Extent.Text))
function Remove-Job { param($Job, [switch]$Force, $ErrorAction) }

function Initialize-TestWartung {
    $script:Gui = @{ Root = $script:TestDir; DataRoot = $script:TestDir; ReadOnly = $false; ReadOnlyReason = 'test'; Token = 'testtoken'
        SafetyPath = 'C:\nicht\vorhanden\Safety.ps1'; WartungPath = 'C:\nicht\vorhanden\Wartung.ps1'; WingetPath = 'C:\nicht\vorhanden\Winget.ps1'
        Jobs = @{}; Offline = $null; PunktFehlt = @{}; Updates = $null; WartungLaufwerke = $null; Tickets = @{}; Catalog = @()
        LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 0 }
    $script:SysCalls = @{ Confirm = 0; Job = 0; Zustimmung = 0; Install = 0; Remove = 0 }
    $script:SysConfirmAntwort = $true
    $script:SysConfirmText = $null
    $script:SysJobArgs = $null
    $script:LwAufrufe = 0
    $script:ZuverlThrow = $false
    $script:TestJournal = @()
    $dir = Join-Path $script:TestDir 'state\wartung'
    if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force }
}
function Start-TestWartung {
    param([string]$Werkzeug, [string]$Laufwerk)
    $b = @{ werkzeug = $Werkzeug }
    if ($Laufwerk) { $b['laufwerk'] = $Laufwerk }
    return (Invoke-TestRoute 'POST' '/api/wartung/start' (ConvertTo-Json -InputObject $b -Compress))
}
function Set-TestUpdates {
    $boese = "Boese`nName" + [string][char]0x202E + 'x'
    $script:Gui.Updates = @{ stand = '2026-10-26T12:00:00'; fehler = $null; liste = @(
            [pscustomobject]@{ id = 'Demo.App'; name = 'Demo App'; installiert = '1.0'; verfuegbar = '1.1'; kategorie = 'Programm' }
            [pscustomobject]@{ id = 'Spiel.Launcher'; name = 'Launcher'; installiert = '2'; verfuegbar = '3'; kategorie = 'Spiel/Launcher' }
            [pscustomobject]@{ id = 'Evil.App'; name = $boese; installiert = "1`r`n0"; verfuegbar = '2'; kategorie = 'Programm' }) }
}
$script:SteuerzeichenRx = '[\x00-\x09\x0B-\x1F\x7F\u2028\u2029\u202A-\u202E\u2066-\u2069]'

Describe 'Routen /api/wartung* (mit Attrappen)' {
    BeforeEach { Initialize-TestWartung }

    It 'GET /api/wartung: Arrays bleiben Arrays, laufend null' {
        $r = Invoke-TestRoute 'GET' '/api/wartung'
        $r.status | Should Be 200
        $r.raw | Should Match '"laufend":null'
        $r.raw | Should Match '"punktFehlt":\[\]'
        $r.raw | Should Match '"werkzeuge":\['
        $r.raw | Should Match '"berichte":\[\{'
        @($r.json.laufwerke).Count | Should Be 2
    }
    It 'GET /api/wartung: laufender Job mit Werkzeug und Abbruch, punktFehlt nur frische Freigaben' {
        $x = Start-TestWartung 'dism.checkhealth'
        $x.status | Should Be 200
        $script:Gui.PunktFehlt['dism.restorehealth'] = Get-Date
        $script:Gui.PunktFehlt['sfc.scannow'] = (Get-Date).AddMinutes(-16)
        $r = Invoke-TestRoute 'GET' '/api/wartung'
        $r.json.laufend.jobId | Should Be $x.json.jobId
        $r.json.laufend.werkzeug | Should Be 'dism.checkhealth'
        $r.json.laufend.abbruch | Should Be 'sofort'
        $r.raw | Should Match '"punktFehlt":\["dism\.restorehealth"\]'
    }
    It 'GET /api/updates: wartungLaeuft nennt das laufende Werkzeug' {
        (Invoke-TestRoute 'GET' '/api/updates').raw | Should Match '"wartungLaeuft":null'
        [void](Start-TestWartung 'dism.checkhealth')
        (Invoke-TestRoute 'GET' '/api/updates').json.wartungLaeuft | Should Be 'dism.checkhealth'
    }
    It 'Laufwerke kommen aus dem Cache (60 s)' {
        [void](Invoke-TestRoute 'GET' '/api/wartung')
        [void](Invoke-TestRoute 'GET' '/api/wartung')
        [void](Start-TestWartung 'chkdsk.scan' 'C:')
        $script:LwAufrufe | Should Be 1
        $script:Gui.WartungLaufwerke.Zeit = (Get-Date).AddSeconds(-61)
        [void](Invoke-TestRoute 'GET' '/api/wartung')
        $script:LwAufrufe | Should Be 2
    }
    It 'ungueltige Eingaben: 400 ohne Dialog und ohne Job' {
        $faelle = @(
            '{}', '{"werkzeug":5}', '{"werkzeug":["dism.checkhealth"]}', '{"werkzeug":null}', '{"werkzeug":"unbekannt"}', '{"werkzeug":"DISM.checkhealth"}',
            '{"werkzeug":"dism.checkhealth\n"}', '{"werkzeug":"a../b"}', ('{"werkzeug":"' + ('a' * 41) + '"}'),
            '{"werkzeug":"dism.checkhealth","laufwerk":"C:"}',
            '{"werkzeug":"dism.checkhealth","laufwerk":5}',
            '{"werkzeug":"chkdsk.scan"}', '{"werkzeug":"chkdsk.scan","laufwerk":"Z:"}', '{"werkzeug":"chkdsk.scan","laufwerk":["C:"]}',
            '{"werkzeug":"chkdsk.scan","laufwerk":"c:"}', '{"werkzeug":"trim","laufwerk":"D:"}',
            '{"werkzeug":"dism.checkhealth","ohnePunkt":"true"}', '{"werkzeug":"dism.checkhealth","ohnePunkt":1}', '{"werkzeug":"dism.checkhealth","ohnePunkt":[true]}',
            '{"werkzeug":"winget.upgrade"}', '{"werkzeug":"winget.upgrade","ids":["Demo.App"]}', '{"werkzeug":"perfmon.rel"}')
        foreach ($f in $faelle) {
            $r = Invoke-TestRoute 'POST' '/api/wartung/start' $f
            if ($r.status -ne 400) { throw "Erwartet 400, war $($r.status): $f" }
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'Nur-Lesen: 403 vor allem anderen' {
        $script:Gui.ReadOnly = $true
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.checkhealth"}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/updates/suchen' '{}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{}').status | Should Be 403
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'diagnose: Job mit allen Argumenten, Dialog "liest nur", Flag-Name nur im Server' {
        $r = Start-TestWartung 'chkdsk.scan' 'C:'
        $r.status | Should Be 200
        $r.json.jobId | Should Match '^[0-9a-f]{8}$'
        ($r.json.PSObject.Properties.Name -join ',') | Should Be 'jobId'
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Job | Should Be 1
        $script:SysConfirmText | Should Match 'Morpheus-Werkzeug mit Administratorrechten starten\?'
        $script:SysConfirmText | Should Match 'chkdsk'
        $script:SysConfirmText | Should Match 'Befehl: chkdsk\.exe C: /scan'
        $script:SysConfirmText | Should Match 'Dieses Werkzeug liest nur und ändert nichts\.'
        $script:SysConfirmText | Should Match "wähle 'Nein'\.$"
        $script:SysConfirmText | Should Not Match 'NICHT UMKEHRBAR'
        $rec = $script:Gui.Jobs[$r.json.jobId]
        $rec.Art | Should Be 'wartung'
        [bool]$rec.Mutating | Should Be $true
        $rec.Werkzeug | Should Be 'chkdsk.scan'
        $rec.Abbruch | Should Be 'sofort'
        $a = $script:SysJobArgs
        $a.Count | Should Be 9
        $a[3] | Should Be $script:TestDir
        $a[4] | Should Be 'chkdsk.scan'
        $a[5] | Should Be 'C:'
        ($null -eq $a[6]) | Should Be $true
        $a[7] | Should Be $false
        $a[8] | Should Be $rec.AbbruchDatei
        $rec.AbbruchDatei | Should Match '\\state\\wartung\\abbruch-[A-Za-z0-9_-]{16}\.flag$'
        Test-Path -LiteralPath $rec.AbbruchDatei | Should Be $false
        Test-Path -LiteralPath (Split-Path -Parent $rec.AbbruchDatei) -PathType Container | Should Be $true
        $r.raw | Should Not Match 'abbruch-'
    }
    It 'wartung und reparatur: Dialogtexte nach 18.5, Mutating' {
        $w = Start-TestWartung 'dns.flush'
        $script:SysConfirmText | Should Match 'Harmlose Wartung: Leert den DNS-Cache\.'
        [bool]$script:Gui.Jobs[$w.json.jobId].Mutating | Should Be $true
        $script:Gui.Jobs = @{}
        $r = Start-TestWartung 'dism.restorehealth'
        $r.status | Should Be 200
        $script:SysConfirmText | Should Match "NICHT UMKEHRBAR: Das Ergebnis lässt sich nicht unter 'Änderungen' zurücknehmen\."
        $script:SysConfirmText | Should Match 'Vorher legt Morpheus einen Wiederherstellungspunkt an und prüft ihn; fehlt er, startet nichts\.'
        $script:SysConfirmText | Should Not Match 'OHNE Wiederherstellungspunkt'
        [bool]$script:Gui.Jobs[$r.json.jobId].Mutating | Should Be $true
        $script:Gui.Jobs[$r.json.jobId].Abbruch | Should Be 'nein'
    }
    It 'Dialog abgelehnt: 403, kein Job' {
        $script:SysConfirmAntwort = $false
        $r = Start-TestWartung 'dism.restorehealth'
        $r.status | Should Be 403
        $r.error | Should Match 'Es wurde nichts geändert\.'
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Job | Should Be 0
        $script:Gui.Jobs.Count | Should Be 0
    }
    It 'zweiter wartung-Job: 409, auch fuer diagnose, ohne Dialog' {
        [void](Start-TestWartung 'dism.checkhealth')
        $r = Start-TestWartung 'dism.checkhealth'
        $r.status | Should Be 409
        $r.error | Should Be 'Es läuft bereits ein Wartungswerkzeug.'
        (Start-TestWartung 'dism.restorehealth').status | Should Be 409
        $script:SysCalls.Confirm | Should Be 1
        $script:SysCalls.Job | Should Be 1
    }
    It 'laufende Aenderung (run-Job) sperrt alle Werkzeuge, auch diagnose' {
        $script:Gui.Jobs['run00001'] = @{ Id = 'run00001'; Art = 'run'; Status = 'running'; Mutating = $true }
        $r = Start-TestWartung 'dism.restorehealth'
        $r.status | Should Be 409
        $r.error | Should Be 'Es läuft bereits eine Änderung.'
        (Start-TestWartung 'dns.flush').status | Should Be 409
        (Start-TestWartung 'dism.checkhealth').status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'laufendes wartung (auch diagnose) sperrt run und undo, run sperrt diagnose' {
        $script:Gui.Catalog = @([pscustomobject]@{ Id = 'fake.a'; Titel = 'Fake A'; Varianten = @(); Neustart = $false })
        $script:TestJournal = @([pscustomobject]@{ id = '20261026-120000-01'; zeit = '2026-10-26T12:00:00'; art = 'ausfuehren'; titel = 'Fake A'; status = 'erledigt' })
        (Start-TestWartung 'dism.restorehealth').status | Should Be 200
        $c = $script:SysCalls.Confirm
        $r = Invoke-TestRoute 'POST' '/api/actions/run' '{"ids":["fake.a"]}'
        $r.status | Should Be 409
        $r.error | Should Be 'Es läuft bereits eine Änderung.'
        (Invoke-TestRoute 'POST' '/api/journal/20261026-120000-01/undo' '{}').status | Should Be 409
        $script:SysCalls.Confirm | Should Be $c
        $script:Gui.Jobs = @{}
        # Diagnose schreibt auch ins Journal: Mutating, blockiert run/undo
        $d = Start-TestWartung 'dism.checkhealth'
        $d.status | Should Be 200
        [bool]$script:Gui.Jobs[$d.json.jobId].Mutating | Should Be $true
        (Invoke-TestRoute 'POST' '/api/actions/run' '{"ids":["fake.a"]}').status | Should Be 409
        (Invoke-TestRoute 'POST' '/api/journal/20261026-120000-01/undo' '{}').status | Should Be 409
        $script:Gui.Jobs = @{}
        (Invoke-TestRoute 'POST' '/api/actions/run' '{"ids":["fake.a"]}').status | Should Be 200
        # umgekehrt: laufendes run blockiert den Diagnose-Start
        (Start-TestWartung 'dism.checkhealth').status | Should Be 409
    }
    It 'Offline-Scan: 409 bei laufendem wartung-Job oder laufendem run, Start wie Jetzt' {
        $text = 'Während ein Wartungswerkzeug oder eine Änderung läuft, ist der Offline-Scan gesperrt (der PC würde neu starten).'
        function Start-TestOfflineCall { param([string]$Pfad) return (Invoke-TestRoute 'POST' $Pfad '{"bestaetigt":true}') }
        [void](Start-TestWartung 'dism.checkhealth')
        $c = $script:SysCalls.Confirm
        $r = Start-TestOfflineCall '/api/defender/offline'
        $r.status | Should Be 409
        $r.error | Should Be $text
        $script:SysCalls.Confirm | Should Be $c
        $script:Gui.Offline = @{ Status = 'countdown'; Ende = (Get-Date).AddSeconds(10); LetzterAbruf = Get-Date; Meldung = '' }
        $j = Start-TestOfflineCall '/api/defender/offline/jetzt'
        $j.status | Should Be 409
        $j.error | Should Be $text
        $script:Gui.Offline.Status | Should Be 'countdown'
        $script:Gui.Offline = $null
        $script:Gui.Jobs = @{}
        $script:Gui.Jobs['run00001'] = @{ Id = 'run00001'; Art = 'run'; Status = 'running'; Mutating = $true }
        $r2 = Start-TestOfflineCall '/api/defender/offline'
        $r2.status | Should Be 409
        $r2.error | Should Be $text
    }
    It 'Offline-Scan-Countdown sperrt den Start: 409' {
        $script:Gui.Offline = @{ Status = 'countdown'; Ende = (Get-Date).AddSeconds(10); LetzterAbruf = Get-Date; Meldung = '' }
        (Start-TestWartung 'dism.checkhealth').status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'ohnePunkt: ohne Freigabe, zu alt, falsche Klasse oder falscher Typ ergibt 400 mit Text' {
        $text = 'Ohne Wiederherstellungspunkt geht es nur, nachdem Windows eben keinen anlegen konnte.'
        $r = Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.restorehealth","ohnePunkt":true}'
        $r.status | Should Be 400
        $r.error | Should Be $text
        $script:Gui.PunktFehlt['dism.restorehealth'] = (Get-Date).AddMinutes(-16)
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.restorehealth","ohnePunkt":true}').error | Should Be $text
        $script:Gui.PunktFehlt['dns.flush'] = Get-Date
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dns.flush","ohnePunkt":true}').error | Should Be $text
        $script:Gui.PunktFehlt['dism.checkhealth'] = Get-Date
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.checkhealth","ohnePunkt":true}').error | Should Be $text
        $script:Gui.PunktFehlt['sfc.scannow'] = Get-Date
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"sfc.scannow","ohnePunkt":"true"}').status | Should Be 400
        # Freigabe gilt nur fuer das Werkzeug, bei dem es scheiterte
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.restorehealth","ohnePunkt":true}').status | Should Be 400
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'ohnePunkt mit frischer Freigabe: Dialog sagt OHNE, Job bekommt true, Freigabe nur einmal' {
        $script:Gui.PunktFehlt['dism.restorehealth'] = (Get-Date).AddMinutes(-14)
        $r = Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.restorehealth","ohnePunkt":true}'
        $r.status | Should Be 200
        $script:SysConfirmText | Should Match 'ACHTUNG: OHNE Wiederherstellungspunkt\. Windows konnte eben keinen anlegen\. Fortfahren nur, wenn du das bewusst so willst\.'
        $script:SysJobArgs[7] | Should Be $true
        $script:Gui.PunktFehlt.ContainsKey('dism.restorehealth') | Should Be $false
        $script:Gui.Jobs = @{}
        (Invoke-TestRoute 'POST' '/api/wartung/start' '{"werkzeug":"dism.restorehealth","ohnePunkt":true}').status | Should Be 400
    }
    It 'Freigabe entsteht nur durch punkt-fehlt (Update-GuiJobs) und das Flag wird danach geloescht' {
        $r = Start-TestWartung 'dism.restorehealth'
        $rec = $script:Gui.Jobs[$r.json.jobId]
        [IO.File]::WriteAllBytes($rec.AbbruchDatei, [byte[]]@())
        $rec.Job = [pscustomobject]@{ State = 'Completed'; ChildJobs = @(); Out = @([pscustomobject]@{ werkzeug = 'dism.restorehealth'; status = 'punkt-fehlt'; meldung = 'x' }) }
        Update-GuiJobs
        $rec.Status | Should Be 'done'
        $script:Gui.PunktFehlt.ContainsKey('dism.restorehealth') | Should Be $true
        Test-Path -LiteralPath $rec.AbbruchDatei | Should Be $false
        # anderes Ergebnis: keine Freigabe
        $script:Gui.PunktFehlt = @{}
        $r2 = Start-TestWartung 'sfc.scannow'
        $rec2 = $script:Gui.Jobs[$r2.json.jobId]
        $rec2.Job = [pscustomobject]@{ State = 'Completed'; ChildJobs = @(); Out = @([pscustomobject]@{ werkzeug = 'sfc.scannow'; status = 'erledigt' }) }
        Update-GuiJobs
        $script:Gui.PunktFehlt.Count | Should Be 0
        # fehlgeschlagener Job: keine Freigabe, Flag trotzdem weg
        $r3 = Start-TestWartung 'dism.checkhealth'
        $rec3 = $script:Gui.Jobs[$r3.json.jobId]
        [IO.File]::WriteAllBytes($rec3.AbbruchDatei, [byte[]]@())
        $rec3.Job = [pscustomobject]@{ State = 'Failed'; ChildJobs = @(); Out = @() }
        Update-GuiJobs
        $rec3.Status | Should Be 'failed'
        $script:Gui.PunktFehlt.Count | Should Be 0
        Test-Path -LiteralPath $rec3.AbbruchDatei | Should Be $false
    }
    It 'abbrechen: legt die Flag-Datei an (sofort), ohne Dialog' {
        $r = Start-TestWartung 'dism.checkhealth'
        $c = $script:SysCalls.Confirm
        $rec = $script:Gui.Jobs[$r.json.jobId]
        $a = Invoke-TestRoute 'POST' '/api/wartung/abbrechen' ('{"jobId":"' + $r.json.jobId + '"}')
        $a.status | Should Be 200
        $a.json.ok | Should Be $true
        ($a.json.meldung.Length -gt 0) | Should Be $true
        Test-Path -LiteralPath $rec.AbbruchDatei -PathType Leaf | Should Be $true
        (Get-Item -LiteralPath $rec.AbbruchDatei).Length | Should Be 0
        $script:SysCalls.Confirm | Should Be $c
        $a.raw | Should Not Match 'abbruch-'
    }
    It 'abbrechen: Abbruch nein ergibt 409 ohne Flag' {
        $r = Start-TestWartung 'dism.restorehealth'
        $rec = $script:Gui.Jobs[$r.json.jobId]
        $a = Invoke-TestRoute 'POST' '/api/wartung/abbrechen' ('{"jobId":"' + $r.json.jobId + '"}')
        $a.status | Should Be 409
        $a.error | Should Be 'Dieses Werkzeug lässt sich nicht sicher abbrechen.'
        Test-Path -LiteralPath $rec.AbbruchDatei | Should Be $false
    }
    It 'abbrechen: falsche, fremde oder beendete jobId' {
        $r = Start-TestWartung 'dism.checkhealth'
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{"jobId":"00000000"}').status | Should Be 409
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{"jobId":"ABCDEF12"}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{"jobId":"..\\x"}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{"jobId":5}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' ('{"jobId":["' + $r.json.jobId + '"]}')).status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{}').status | Should Be 400
        $script:Gui.Jobs['a0000001'] = @{ Id = 'a0000001'; Art = 'scan'; Status = 'running'; Abbruch = 'sofort'; AbbruchDatei = (Join-Path $script:TestDir 'state\wartung\abbruch-fremd.flag') }
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' '{"jobId":"a0000001"}').status | Should Be 409
        Test-Path -LiteralPath (Join-Path $script:TestDir 'state\wartung\abbruch-fremd.flag') | Should Be $false
        $script:Gui.Jobs[$r.json.jobId].Status = 'done'
        (Invoke-TestRoute 'POST' '/api/wartung/abbrechen' ('{"jobId":"' + $r.json.jobId + '"}')).status | Should Be 409
        (Invoke-TestRoute 'GET' '/api/wartung/abbrechen').status | Should Be 405
    }
    It 'Initialize-GuiWartungDir loescht alte .flag-Dateien' {
        $dir = Join-Path $script:TestDir 'state\wartung'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'abbruch-alt.flag'), '')
        [IO.File]::WriteAllText((Join-Path $dir 'andere.txt'), 'x')
        Initialize-GuiWartungDir
        Test-Path -LiteralPath (Join-Path $dir 'abbruch-alt.flag') | Should Be $false
        Test-Path -LiteralPath (Join-Path $dir 'andere.txt') | Should Be $true
    }
    It 'zuverlaessigkeit: ohne Dialog, Ergebnis ok/meldung, Fehler ergibt 500' {
        $r = Invoke-TestRoute 'POST' '/api/wartung/zuverlaessigkeit' '{}'
        $r.status | Should Be 200
        $r.json.ok | Should Be $true
        $r.json.meldung | Should Be 'Geoeffnet.'
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
        $script:ZuverlThrow = $true
        $e = Invoke-TestRoute 'POST' '/api/wartung/zuverlaessigkeit' '{}'
        $e.status | Should Be 500
        $e.error | Should Match 'Explorer nicht startbar'
        (Invoke-TestRoute 'GET' '/api/wartung/zuverlaessigkeit').status | Should Be 405
    }
}

Describe 'Routen /api/updates* (mit Attrappen)' {
    BeforeEach { Initialize-TestWartung }

    It 'GET /api/updates vor der ersten Suche: stand null, leere Liste' {
        $r = Invoke-TestRoute 'GET' '/api/updates'
        $r.status | Should Be 200
        $r.raw | Should Match '"stand":null'
        $r.raw | Should Match '"liste":\[\]'
        $r.raw | Should Match '"suche":null'
        $r.raw | Should Match '"laufend":null'
        $r.raw | Should Match '"punktFehlt":false'
    }
    It 'suchen: Job updatesuche ohne Dialog, zweiter Aufruf liefert dieselbe jobId' {
        $a = Invoke-TestRoute 'POST' '/api/updates/suchen' '{}'
        $a.status | Should Be 200
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 1
        $script:SysJobArgs[0] | Should Be $script:TestDir
        $script:SysJobArgs[1] | Should Be 'C:\nicht\vorhanden\Winget.ps1'
        $rec = $script:Gui.Jobs[$a.json.jobId]
        $rec.Art | Should Be 'updatesuche'
        [bool]$rec.Mutating | Should Be $false
        $b = Invoke-TestRoute 'POST' '/api/updates/suchen' '{}'
        $b.json.jobId | Should Be $a.json.jobId
        $script:SysCalls.Job | Should Be 1
        (Invoke-TestRoute 'GET' '/api/updates').json.suche | Should Be $a.json.jobId
    }
    It 'suchen wird von einer laufenden Aenderung nicht blockiert' {
        $script:Gui.Jobs['run00001'] = @{ Id = 'run00001'; Art = 'run'; Status = 'running'; Mutating = $true }
        (Invoke-TestRoute 'POST' '/api/updates/suchen' '{}').status | Should Be 200
    }
    It 'Ergebnis der Suche landet im Server und in GET /api/updates' {
        $a = Invoke-TestRoute 'POST' '/api/updates/suchen' '{}'
        $rec = $script:Gui.Jobs[$a.json.jobId]
        $erg = [pscustomobject]@{ status = 'ok'; stand = (Get-Date '2026-10-26T12:30:00'); fehler = $null; exitCode = 0
            zeilen = @([pscustomobject]@{ Name = 'Demo App'; Id = 'Demo.App'; Installiert = '1.0'; Verfuegbar = '1.1'; Kategorie = 'Programm' }) }
        $rec.Job = [pscustomobject]@{ State = 'Completed'; ChildJobs = @(); Out = @($erg) }
        Update-GuiJobs
        $r = Invoke-TestRoute 'GET' '/api/updates'
        $r.json.stand | Should Be '2026-10-26T12:30:00'
        @($r.json.liste).Count | Should Be 1
        $r.json.liste[0].id | Should Be 'Demo.App'
        $r.json.liste[0].name | Should Be 'Demo App'
        $r.json.liste[0].installiert | Should Be '1.0'
        $r.json.liste[0].verfuegbar | Should Be '1.1'
        $r.json.liste[0].kategorie | Should Be 'Programm'
        $r.raw | Should Match '"liste":\[\{'
        $r.raw | Should Match '"suche":null'
    }
    It 'installieren: ungueltige ids ergeben 400 ohne Dialog' {
        Set-TestUpdates
        $viele = ConvertTo-Json -InputObject @(1..31 | ForEach-Object { 'Demo.App' + $_ }) -Compress
        $faelle = @(
            '{}', '{"ids":null}', '{"ids":"Demo.App"}', '{"ids":{"a":1}}', '{"ids":[]}',
            '{"ids":["Gibt.Es.Nicht"]}', '{"ids":["demo.app"]}', '{"ids":["Spiel.Launcher"]}',
            '{"ids":["Demo.App","Demo.App"]}', '{"ids":["Demo.App",5]}', '{"ids":[["Demo.App"]]}',
            ('{"ids":' + $viele + '}'), '{"ids":["Demo.App"],"ohnePunkt":"ja"}', '{"ids":["Demo.App"],"ohnePunkt":true}')
        foreach ($f in $faelle) {
            $r = Invoke-TestRoute 'POST' '/api/updates/installieren' $f
            if ($r.status -ne 400) { throw "Erwartet 400, war $($r.status): $f" }
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'installieren ohne vorherige Suche: 400' {
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}').status | Should Be 400
    }
    It 'installieren: Job wartung/winget.upgrade, Pakete aus der Server-Liste, Dialog ohne Steuerzeichen' {
        Set-TestUpdates
        $r = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App","Evil.App"],"pakete":[{"id":"Boese.Paket","name":"x","von":"1","auf":"2"}]}'
        $r.status | Should Be 200
        $script:SysCalls.Confirm | Should Be 1
        $script:SysConfirmText | Should Match '^Diese Programme mit winget aktualisieren\?\n\n'
        $script:SysConfirmText | Should Match '• Demo App: 1\.0 → 1\.1'
        $script:SysConfirmText | Should Match '• Boese Name x: 1  0 → 2'
        $script:SysConfirmText | Should Not Match $script:SteuerzeichenRx
        $script:SysConfirmText | Should Not Match 'Boese\.Paket'
        $script:SysConfirmText | Should Match "Programm-Updates lassen sich nicht über 'Änderungen' zurücknehmen\. Vorher wird ein Wiederherstellungspunkt angelegt\. winget lädt aus den Herstellerquellen und nimmt die Lizenzbedingungen der Pakete an\."
        $rec = $script:Gui.Jobs[$r.json.jobId]
        $rec.Art | Should Be 'wartung'
        [bool]$rec.Mutating | Should Be $true
        $rec.Werkzeug | Should Be 'winget.upgrade'
        $rec.Abbruch | Should Be 'nach-paket'
        $a = $script:SysJobArgs
        $a[4] | Should Be 'winget.upgrade'
        ($null -eq $a[5]) | Should Be $true
        $a[7] | Should Be $false
        $a[8] | Should Be $rec.AbbruchDatei
        $p = @(ConvertFrom-Json -InputObject $a[6] | ForEach-Object { $_ })
        $p.Count | Should Be 2
        $p[0].id | Should Be 'Demo.App'
        $p[0].von | Should Be '1.0'
        $p[0].auf | Should Be '1.1'
        $p[1].id | Should Be 'Evil.App'
        $a[6] | Should Match '^\[\{"id":"Demo\.App","name":"Demo App","von":"1\.0","auf":"1\.1"\},'
        (Invoke-TestRoute 'GET' '/api/updates').json.laufend | Should Be $r.json.jobId
    }
    It 'installieren: ein Paket wird als JSON-Array uebergeben' {
        Set-TestUpdates
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}').status | Should Be 200
        $script:SysJobArgs[6] | Should Match '^\[\{"id":"Demo\.App".*\}\]$'
    }
    It 'installieren: hoechstens 30 Zeilen im Dialog' {
        $script:Gui.Updates = @{ stand = 'x'; fehler = $null; liste = @(1..30 | ForEach-Object { [pscustomobject]@{ id = "P.$_"; name = "Programm $_"; installiert = '1'; verfuegbar = '2'; kategorie = 'Programm' } }) }
        $ids = ConvertTo-Json -InputObject @(1..30 | ForEach-Object { "P.$_" }) -Compress
        (Invoke-TestRoute 'POST' '/api/updates/installieren' ('{"ids":' + $ids + '}')).status | Should Be 200
        @($script:SysConfirmText -split "`n" | Where-Object { $_ -like '• *' }).Count | Should Be 30
    }
    It 'installieren: Dialog abgelehnt 403, laufende Aenderung 409, laufendes wartung 409' {
        Set-TestUpdates
        $script:SysConfirmAntwort = $false
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}').status | Should Be 403
        $script:SysCalls.Job | Should Be 0
        $script:Gui.Jobs.Count | Should Be 0
        $script:SysConfirmAntwort = $true
        $script:Gui.Jobs['run00001'] = @{ Id = 'run00001'; Art = 'run'; Status = 'running'; Mutating = $true }
        $e = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}'
        $e.status | Should Be 409
        $e.error | Should Be 'Es läuft bereits eine Änderung.'
        $script:Gui.Jobs = @{}
        [void](Start-TestWartung 'dism.checkhealth')
        $w = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}'
        $w.status | Should Be 409
        $w.error | Should Be 'Es läuft bereits ein Wartungswerkzeug.'
    }
    It 'Suche und Installation schliessen sich aus (409), andere Wartung blockiert die Suche nicht' {
        Set-TestUpdates
        $script:Gui.Jobs['such0001'] = @{ Id = 'such0001'; Art = 'updatesuche'; Status = 'running'; Mutating = $false }
        $i = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"]}'
        $i.status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
        $script:Gui.Jobs = @{}
        $script:Gui.Jobs['wart0001'] = @{ Id = 'wart0001'; Art = 'wartung'; Status = 'running'; Mutating = $true; Werkzeug = 'winget.upgrade' }
        (Invoke-TestRoute 'POST' '/api/updates/suchen' '{}').status | Should Be 409
        $script:Gui.Jobs = @{}
        $script:Gui.Jobs['wart0002'] = @{ Id = 'wart0002'; Art = 'wartung'; Status = 'running'; Mutating = $false; Werkzeug = 'dism.checkhealth' }
        (Invoke-TestRoute 'POST' '/api/updates/suchen' '{}').status | Should Be 200
    }
    It 'installieren mit ohnePunkt: nur mit Freigabe von winget.upgrade, einmalig' {
        Set-TestUpdates
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"],"ohnePunkt":true}').status | Should Be 400
        $script:Gui.PunktFehlt['winget.upgrade'] = @{ Zeit = (Get-Date); Ids = @('Demo.App') }
        (Invoke-TestRoute 'GET' '/api/updates').raw | Should Match '"punktFehlt":true'
        $r = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"],"ohnePunkt":true}'
        $r.status | Should Be 200
        $script:SysConfirmText | Should Match 'ACHTUNG: OHNE Wiederherstellungspunkt'
        $script:SysConfirmText | Should Not Match 'Vorher wird ein Wiederherstellungspunkt angelegt'
        $script:SysJobArgs[7] | Should Be $true
        $script:Gui.Jobs = @{}
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"],"ohnePunkt":true}').status | Should Be 400
    }
    It 'installieren mit ohnePunkt: Freigabe gilt nur fuer dieselbe Id-Menge' {
        Set-TestUpdates
        $script:Gui.PunktFehlt['winget.upgrade'] = @{ Zeit = (Get-Date); Ids = @('Demo.App', 'Evil.App') }
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"],"ohnePunkt":true}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App","Evil.App","Neu.App"],"ohnePunkt":true}').status | Should Be 400
        $script:SysCalls.Confirm | Should Be 0
        # Reihenfolge ist egal
        $r = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Evil.App","Demo.App"],"ohnePunkt":true}'
        $r.status | Should Be 200
        $script:Gui.PunktFehlt.ContainsKey('winget.upgrade') | Should Be $false
    }
    It 'Freigabe nach punkt-fehlt eines winget-Laufs speichert die Id-Menge' {
        Set-TestUpdates
        $r = Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Evil.App","Demo.App"]}'
        $rec = $script:Gui.Jobs[$r.json.jobId]
        (@($rec.Ids) -join ',') | Should Be 'Demo.App,Evil.App'
        $rec.Job = [pscustomobject]@{ State = 'Completed'; ChildJobs = @(); Out = @([pscustomobject]@{ werkzeug = 'winget.upgrade'; status = 'punkt-fehlt' }) }
        Update-GuiJobs
        (@($script:Gui.PunktFehlt['winget.upgrade'].Ids) -join ',') | Should Be 'Demo.App,Evil.App'
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App"],"ohnePunkt":true}').status | Should Be 400
        (Invoke-TestRoute 'POST' '/api/updates/installieren' '{"ids":["Demo.App","Evil.App"],"ohnePunkt":true}').status | Should Be 200
    }
    It 'installieren: gekuerzte Id aus der Liste ergibt 400 ohne Dialog' {
        $script:Gui.Updates = @{ stand = 'x'; fehler = $null; liste = @([pscustomobject]@{ id = ('Demo.Gekuerzt' + [string][char]0x2026); name = 'Gekuerzt'; installiert = '1'; verfuegbar = '2'; kategorie = 'Programm' }) }
        $id = 'Demo.Gekuerzt' + [string][char]0x2026
        $r = Invoke-TestRoute 'POST' '/api/updates/installieren' (ConvertTo-Json -InputObject @{ ids = @($id) } -Compress)
        $r.status | Should Be 400
        $r.error | Should Be 'Die Programm-Id ist unvollständig oder ungültig (von winget gekürzt). Bitte über winget selbst aktualisieren.'
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
}

Describe 'Wartungsberichte im iframe und Rueckgaengig-Sperre (mit Attrappen)' {
    BeforeEach {
        Initialize-TestWartung
        $script:Rep = Join-Path $script:TestDir 'reports'
        New-Item -ItemType Directory -Path $script:Rep -Force | Out-Null
        foreach ($n in 'morpheus-energy_2026-10-26_153012.html', 'morpheus-akku_2026-10-26_153012.html', 'morpheus-schlaf_2026-10-26_153012.html', 'pc-check_2026-10-26_1200.html',
            'morpheus-energy_2026-10-26_153012.htm', 'morpheus-foo_2026-10-26_153012.html', 'Morpheus-energy_2026-10-26_153012.html', 'morpheus-energy_2026-10-26_1530.html', 'morpheus-energy_2026-10-26_153012.json') {
            [IO.File]::WriteAllText((Join-Path $script:Rep $n), '<html><body>Bericht</body></html>')
        }
    }

    It 'Ticket und Abruf fuer energy, akku und schlaf: einmalig, Name muss passen' {
        foreach ($n in 'morpheus-energy_2026-10-26_153012.html', 'morpheus-akku_2026-10-26_153012.html', 'morpheus-schlaf_2026-10-26_153012.html', 'pc-check_2026-10-26_1200.html') {
            $t = Invoke-TestRoute 'POST' '/api/report-ticket' ('{"name":"' + $n + '"}')
            $t.status | Should Be 200
            $k = $t.json.ticket
            ($k.Length -ge 32) | Should Be $true
            $g1 = Invoke-TestRoute 'GET' ('/report/' + $n) '' @{ k = $k }
            $g1.status | Should Be 200
            $g1.raw | Should Match 'Bericht'
            (Invoke-TestRoute 'GET' ('/report/' + $n) '' @{ k = $k }).status | Should Be 401
        }
        $t2 = Invoke-TestRoute 'POST' '/api/report-ticket' '{"name":"morpheus-energy_2026-10-26_153012.html"}'
        (Invoke-TestRoute 'GET' '/report/morpheus-akku_2026-10-26_153012.html' '' @{ k = $t2.json.ticket }).status | Should Be 401
    }
    It 'fremde Namen bekommen kein Ticket (404), auch wenn die Datei existiert' {
        $namen = @('morpheus-energy_2026-10-26_153012.htm', 'morpheus-foo_2026-10-26_153012.html', 'Morpheus-energy_2026-10-26_153012.html',
            'morpheus-energy_2026-10-26_1530.html', 'morpheus-energy_2026-10-26_153012.json', 'morpheus-energy_../x.html', 'morpheus-energy_../../pc-check_2026-10-26_1200.html',
            '..\morpheus-energy_2026-10-26_153012.html', 'morpheus-energy_2026-10-26_153012.html ', "morpheus-energy_2026-10-26_153012.html`n",
            'morpheus-energy_2026-10-26_153012.html:x', 'morpheus-energy_2026-10-26_999999.html')
        foreach ($n in $namen) {
            $b = ConvertTo-Json -InputObject @{ name = $n } -Compress
            $r = Invoke-TestRoute 'POST' '/api/report-ticket' $b
            if ($r.status -ne 404) { throw "Erwartet 404, war $($r.status): $n" }
        }
        (Invoke-TestRoute 'POST' '/api/report-ticket' '{"name":5}').status | Should Be 404
    }
    It 'Resolve-GuiReportPath: Wartungsberichte nur als html, pc-check-Berichte unveraendert' {
        (Resolve-GuiReportPath 'morpheus-energy_2026-10-26_153012.html' 'html') | Should Match 'reports\\morpheus-energy_2026-10-26_153012\.html$'
        (Resolve-GuiReportPath 'morpheus-energy_2026-10-26_153012.html' 'json') | Should BeNullOrEmpty
        (Resolve-GuiReportPath 'morpheus-energy_2026-10-26_153012.json' 'json') | Should BeNullOrEmpty
        (Resolve-GuiReportPath 'pc-check_2026-10-26_1200.html' 'html') | Should Match 'pc-check_2026-10-26_1200\.html$'
        (Resolve-GuiReportPath 'morpheus-energy_2026-10-26_153013.html' 'html') | Should BeNullOrEmpty
    }
    It '/report/ ohne Ticket: 401' {
        (Invoke-TestRoute 'GET' '/report/morpheus-energy_2026-10-26_153012.html' '' @{}).status | Should Be 401
    }
    It 'undo: Eintrag mit art wartung/update ergibt 400 vor dem Dialog, ausfuehren geht' {
        $script:TestJournal = @(
            [pscustomobject]@{ id = '20261026-120000-01'; zeit = '2026-10-26T12:00:00'; art = 'wartung'; titel = 'DISM'; status = 'erledigt' },
            [pscustomobject]@{ id = '20261026-120001-01'; zeit = '2026-10-26T12:00:01'; art = 'update'; titel = 'Update: Demo'; status = 'erledigt' },
            [pscustomobject]@{ id = '20261026-120002-01'; zeit = '2026-10-26T12:00:02'; art = 'rueckgaengig'; titel = 'R'; status = 'erledigt' },
            [pscustomobject]@{ id = '20261026-120003-01'; zeit = '2026-10-26T12:00:03'; art = 'ausfuehren'; titel = 'Fake'; status = 'erledigt' })
        foreach ($id in '20261026-120000-01', '20261026-120001-01', '20261026-120002-01') {
            $r = Invoke-TestRoute 'POST' ('/api/journal/' + $id + '/undo') '{}'
            $r.status | Should Be 400
            $r.error | Should Be 'Für diesen Eintrag gibt es kein Rückgängig.'
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
        (Invoke-TestRoute 'POST' '/api/journal/20261026-120003-01/undo' '{}').status | Should Be 200
        $script:SysCalls.Job | Should Be 1
    }
}

Describe 'Start-GuiJob und Job-Scripts fuer wartung/updatesuche' {
    BeforeEach { Initialize-TestWartung }

    It 'Nur-Lesen sperrt wartung und updatesuche in Start-GuiJob (403, kein Dialog, kein Job)' {
        $script:Gui.ReadOnly = $true
        foreach ($art in 'wartung', 'updatesuche') {
            $code = 0
            try { [void](Start-GuiJob $art @('a') $false 'Text') } catch { $code = [int]$_.Exception.Data['status'] }
            $code | Should Be 403
        }
        $script:SysCalls.Job | Should Be 0
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'wartung ohne Bestaetigungstext: 500, updatesuche braucht keinen' {
        $code = 0
        try { [void](Start-GuiJob 'wartung' @('a') $true) } catch { $code = [int]$_.Exception.Data['status'] }
        $code | Should Be 500
        $script:SysCalls.Job | Should Be 0
        [void](Start-GuiJob 'updatesuche' @('a', 'b') $false)
        $script:SysCalls.Job | Should Be 1
        $script:SysCalls.Confirm | Should Be 0
    }
    It 'wartung: abgelehnter Dialog ergibt 403 ohne Job' {
        $script:SysConfirmAntwort = $false
        $code = 0
        try { [void](Start-GuiJob 'wartung' @('a') $true 'Text') } catch { $code = [int]$_.Exception.Data['status'] }
        $code | Should Be 403
        $script:SysCalls.Job | Should Be 0
        $script:Gui.Jobs.Count | Should Be 0
    }
    It 'Extra-Felder landen im Job-Record' {
        $id = Start-GuiJob 'wartung' @('a') $true 'Text' @{ Werkzeug = 'trim'; Abbruch = 'sofort'; AbbruchDatei = 'X:\y.flag' }
        $rec = $script:Gui.Jobs[$id]
        $rec.Werkzeug | Should Be 'trim'
        $rec.Abbruch | Should Be 'sofort'
        $rec.AbbruchDatei | Should Be 'X:\y.flag'
        $rec.Art | Should Be 'wartung'
    }
    It 'Server.ps1 (statisch): Sperrlisten und Update-GuiJobs' {
        $script:ServerText | Should Match "ReadOnly -and \(\`$Art -in 'run', 'undo', 'scan', 'speicher', 'defender', 'sysinternals', 'wartung', 'updatesuche'\)"
        $script:ServerText | Should Match "if \(\`$Art -in 'run', 'undo', 'defender', 'sysinternals', 'wartung'\)"
        $script:ServerText | Should Match 'Complete-GuiJob \$rec'
        $script:ServerText | Should Match "-ceq 'punkt-fehlt'"
    }
    It 'Job-Script wartung: Parameter, JSON-Pakete, OhnePunkt nur bei true' {
        $s = $script:GuiJobScripts['wartung'].ToString()
        $s | Should Match 'param\(\$Root, \$SafetyPath, \$WartungPath, \$DataRoot, \$Werkzeug, \$Laufwerk, \$PaketeJson, \$OhnePunkt, \$AbbruchDatei\)'
        $s | Should Match '\. \$SafetyPath'
        $s | Should Match '\. \$WartungPath'
        $s | Should Match 'ConvertFrom-Json'
        $s | Should Match '\$OhnePunkt -is \[bool\]'
        $s | Should Match 'Invoke-MorpheusWartung @a'
    }
    It 'Job-Script wartung: Pakete aus JSON werden Objekte, leer wird weggelassen (Attrappe fuer Invoke-MorpheusWartung)' {
        $script:WJ = $null
        function Invoke-MorpheusWartung {
            param($Root, $DataRoot, $Werkzeug, $Laufwerk, $Pakete, [switch]$OhnePunkt, $AbbruchDatei)
            $h = @{}
            foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }
            $script:WJ = $h
        }
        $tmp = Join-Path $script:TestDir 'leer.ps1'
        [IO.File]::WriteAllText($tmp, '# leer')
        $json = '[{"id":"A.B","name":"Ein Name","von":"1","auf":"2"}]'
        & $script:GuiJobScripts['wartung'] 'R' $tmp $tmp 'D' 'winget.upgrade' $null $json $true 'F'
        $script:WJ.Werkzeug | Should Be 'winget.upgrade'
        $script:WJ.OhnePunkt | Should Be $true
        $script:WJ.AbbruchDatei | Should Be 'F'
        $script:WJ.ContainsKey('Laufwerk') | Should Be $false
        @($script:WJ.Pakete).Count | Should Be 1
        $script:WJ.Pakete[0].id | Should Be 'A.B'
        $script:WJ.Pakete[0].auf | Should Be '2'
        & $script:GuiJobScripts['wartung'] 'R' $tmp $tmp 'D' 'chkdsk.scan' 'C:' $null $false $null
        $script:WJ.Laufwerk | Should Be 'C:'
        $script:WJ.ContainsKey('Pakete') | Should Be $false
        $script:WJ.ContainsKey('OhnePunkt') | Should Be $false
        $script:WJ.ContainsKey('AbbruchDatei') | Should Be $false
        & $script:GuiJobScripts['wartung'] 'R' $tmp $tmp 'D' 'dns.flush' $null '[]' 'true' $null
        $script:WJ.ContainsKey('Pakete') | Should Be $false
        $script:WJ.ContainsKey('OhnePunkt') | Should Be $false
    }
    It 'Job-Script updatesuche' {
        $s = $script:GuiJobScripts['updatesuche'].ToString()
        $s | Should Match 'param\(\$Root, \$WingetLibPath\)'
        $s | Should Match '\. \$WingetLibPath'
        $s | Should Match 'Get-MorpheusWingetUpdates -Fortschritt'
    }
}

# --- Datenordner-Reparatur (18.10): Attrappen, kein echter Datenordner ---
$script:DnCalls = @{ Repair = 0; Init = 0; InitBeiseite = $false; InitPfad = $null; RepairPfad = $null }
$script:DnFail = $false
function Repair-MorpheusDatenordner {
    param([string]$Path)
    $script:DnCalls.Repair++; $script:DnCalls.RepairPfad = $Path
    if ($script:DnFail) { throw 'Attrappe: Reparatur fehlgeschlagen' }
    return [pscustomobject]@{ zustand = 'ok'; entfernt = 2; meldung = 'Es wurden 2 zusätzliche Rechte entfernt.' }
}
function Initialize-MorpheusDataDir {
    param([string]$Path, [switch]$Beiseite)
    $script:DnCalls.Init++; $script:DnCalls.InitPfad = $Path; $script:DnCalls.InitBeiseite = [bool]$Beiseite
    if ($script:DnFail) { throw 'Attrappe: Anlegen fehlgeschlagen' }
    return $Path
}

Describe 'Route /api/datenordner/reparieren und Undo-Sperre (18.10)' {
    BeforeEach {
        Initialize-TestWartung
        $script:DnCalls = @{ Repair = 0; Init = 0; InitBeiseite = $false; InitPfad = $null; RepairPfad = $null }
        $script:DnFail = $false
        $bos = 'Boese' + [char]10 + 'Konto' + [string][char]0x202E + 'x'
        $zustand = [pscustomobject]@{ zustand = 'reparierbar'; objekte = 3; gruende = @('x')
            konten = @([pscustomobject]@{ sid = 'S-1-5-21-1-2-3-1001'; name = ('DEMO-PC\' + $bos); rechte = 'schreiben' }) }
        $script:Gui.ReadOnly = $true
        $script:Gui.Admin = $true
        $script:Gui.TempSicher = $true
        $script:Gui.ReportCache = @{}
        $script:Gui.Datenordner = @{ Zustand = $zustand; Pfad = 'C:\ProgramData\Morpheus'; Repariert = $false }
        $rep = Join-Path $script:TestDir 'state\datenordner-reparatur.json'
        if (Test-Path -LiteralPath $rep) { Remove-Item -LiteralPath $rep -Force }
    }
    AfterEach {
        $rep = Join-Path $script:TestDir 'state\datenordner-reparatur.json'
        if (Test-Path -LiteralPath $rep) { Remove-Item -LiteralPath $rep -Force }
    }
    function Post-Dn([string]$Json) { return (Invoke-TestRoute 'POST' '/api/datenordner/reparieren' $Json) }

    It 'Validierung: art genau reparieren oder neu, sonst 400 ohne Dialog' {
        foreach ($j in '{}', '{"art":"Reparieren"}', '{"art":"NEU"}', '{"art":1}', '{"art":["reparieren"]}', '{"art":"reparieren "}', '{"art":null}') {
            (Post-Dn $j).status | Should Be 400
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:DnCalls.Repair | Should Be 0
        (Invoke-TestRoute 'GET' '/api/datenordner/reparieren' '').status | Should Be 405
    }
    It '409 ohne gemeldeten reparierbaren Zustand, bei anderem Zustand und nach Reparatur' {
        $script:Gui.Datenordner = $null
        (Post-Dn '{"art":"reparieren"}').status | Should Be 409
        $script:Gui.Datenordner = @{ Zustand = [pscustomobject]@{ zustand = 'ok'; konten = @(); objekte = 0 }; Pfad = 'C:\x'; Repariert = $false }
        (Post-Dn '{"art":"neu"}').status | Should Be 409
        $script:Gui.Datenordner = @{ Zustand = [pscustomobject]@{ zustand = 'reparierbar'; konten = @(); objekte = 1 }; Pfad = 'C:\x'; Repariert = $true }
        (Post-Dn '{"art":"reparieren"}').status | Should Be 409
        $script:SysCalls.Confirm | Should Be 0
        $script:DnCalls.Repair | Should Be 0
        $script:DnCalls.Init | Should Be 0
    }
    It 'ohne Adminrechte 403 ohne Dialog' {
        $script:Gui.Admin = $false
        (Post-Dn '{"art":"reparieren"}').status | Should Be 403
        $script:SysCalls.Confirm | Should Be 0
        $script:DnCalls.Repair | Should Be 0
    }
    It 'ohne gesicherten Temp-Ordner 409 vor dem Dialog' {
        foreach ($tv in $false, $null) {
            $script:Gui.TempSicher = $tv
            foreach ($art in 'reparieren', 'neu') {
                $r = Post-Dn ('{"art":"' + $art + '"}')
                $r.status | Should Be 409
                $r.error | Should Be 'Kein gesicherter Temp-Ordner; Reparatur nicht möglich.'
            }
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:DnCalls.Repair | Should Be 0
        $script:DnCalls.Init | Should Be 0
    }
    It 'POST /api/checklist im Nur-Lesen-Modus 403, sonst gültig' {
        $r = Invoke-TestRoute 'POST' '/api/checklist' '{}'
        $r.status | Should Be 403
        $script:Gui.ReadOnly = $false
        (Invoke-TestRoute 'POST' '/api/checklist' '{}').status | Should Be 200
        Remove-Item -LiteralPath (Join-Path $script:TestDir 'state\checklist.json') -Force -ErrorAction SilentlyContinue
    }
    It 'im Nur-Lesen-Modus erlaubt; Dialog abgelehnt: 403 und nichts aufgerufen' {
        $script:SysConfirmAntwort = $false
        foreach ($art in 'reparieren', 'neu') {
            (Post-Dn ('{"art":"' + $art + '"}')).status | Should Be 403
        }
        $script:SysCalls.Confirm | Should Be 2
        $script:DnCalls.Repair | Should Be 0
        $script:DnCalls.Init | Should Be 0
        $script:Gui.Datenordner.Repariert | Should Be $false
    }
    It 'reparieren: Dialogtext mit Pfad und Konten ohne Steuerzeichen, Erfolg setzt repariert, zweiter Aufruf 409' {
        $r = Post-Dn '{"art":"reparieren"}'
        $r.status | Should Be 200
        $r.json.ok | Should Be $true
        $r.json.zustand | Should Be 'ok'
        $r.json.meldung | Should Match 'Es wurden 2 zusätzliche Rechte entfernt\.'
        $r.json.meldung | Should Match 'Morpheus bitte beenden und über das Startmenü neu starten\.'
        $script:DnCalls.Repair | Should Be 1
        $script:DnCalls.RepairPfad | Should Be 'C:\ProgramData\Morpheus'
        $script:DnCalls.Init | Should Be 0
        $script:Gui.Datenordner.Repariert | Should Be $true
        $t = $script:SysConfirmText
        $t | Should Match 'C:\\ProgramData\\Morpheus'
        $t | Should Match 'DEMO-PC\\Boese Konto x \(schreiben\)'
        $t | Should Match 'temp und tools'
        $t | Should Match "Hast du das gerade nicht selbst in Morpheus angeklickt, wähle 'Nein'\."
        ([regex]::IsMatch(($t -replace "`n", ''), '[\u0000-\u001F\u007F\u0085\u200B-\u200F\u2028\u2029\u202A-\u202E]')) | Should Be $false
        (Post-Dn '{"art":"reparieren"}').status | Should Be 409
        $script:DnCalls.Repair | Should Be 1
    }
    It 'neu: ruft Initialize-MorpheusDataDir mit -Beiseite, Dialog nennt das Beiseitelegen' {
        $r = Post-Dn '{"art":"neu"}'
        $r.status | Should Be 200
        $r.json.ok | Should Be $true
        $script:DnCalls.Init | Should Be 1
        $script:DnCalls.InitBeiseite | Should Be $true
        $script:DnCalls.InitPfad | Should Be 'C:\ProgramData\Morpheus'
        $script:DnCalls.Repair | Should Be 0
        $script:SysConfirmText | Should Match 'beiseitegelegt und leer neu angelegt'
        $r.json.meldung | Should Match 'Morpheus bitte beenden und über das Startmenü neu starten\.'
        $script:Gui.Datenordner.Repariert | Should Be $true
    }
    It 'Fehler der Reparatur: 500 mit Text, nicht repariert' {
        $script:DnFail = $true
        $r = Post-Dn '{"art":"reparieren"}'
        $r.status | Should Be 500
        $r.error | Should Match 'Attrappe: Reparatur fehlgeschlagen'
        $script:Gui.Datenordner.Repariert | Should Be $false
    }
    It 'andere ändernde Routen bleiben im Nur-Lesen-Modus gesperrt' {
        (Invoke-TestRoute 'POST' '/api/actions/run' '{"ids":["x"]}').status | Should Be 403
        (Invoke-TestRoute 'POST' '/api/journal/20261026-120003-01/undo' '{}').status | Should Be 403
    }
    It '/api/session: datenordner-Feld und reparaturZeit' {
        $r = Invoke-TestRoute 'GET' '/api/session' ''
        $r.status | Should Be 200
        $r.json.datenordner.zustand | Should Be 'reparierbar'
        $r.json.datenordner.objekte | Should Be 3
        $r.json.datenordner.pfad | Should Be 'C:\ProgramData\Morpheus'
        $r.json.datenordner.repariert | Should Be $false
        @($r.json.datenordner.konten).Count | Should Be 1
        $r.json.datenordner.konten[0].sid | Should Be 'S-1-5-21-1-2-3-1001'
        $r.json.datenordner.konten[0].rechte | Should Be 'schreiben'
        $r.json.reparaturZeit | Should BeNullOrEmpty
        $script:Gui.Datenordner = $null
        (Invoke-TestRoute 'GET' '/api/session' '').json.datenordner | Should BeNullOrEmpty
        $dir = Join-Path $script:TestDir 'state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $jung = (Get-Date).AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss')
        [IO.File]::WriteAllText((Join-Path $dir 'datenordner-reparatur.json'), ('{"version":1,"zeit":"' + $jung + '","konten":[]}'))
        (Invoke-TestRoute 'GET' '/api/session' '').json.reparaturZeit | Should Be $jung
        $alt = (Get-Date).AddDays(-8).ToString('yyyy-MM-ddTHH:mm:ss')
        [IO.File]::WriteAllText((Join-Path $dir 'datenordner-reparatur.json'), ('{"version":1,"zeit":"' + $alt + '","konten":[]}'))
        (Invoke-TestRoute 'GET' '/api/session' '').json.reparaturZeit | Should BeNullOrEmpty
    }
    It 'Undo-Sperre: Eintrag vor der Reparatur ergibt 409 ohne vorReparatur (vor dem Dialog)' {
        $script:Gui.ReadOnly = $false
        $dir = Join-Path $script:TestDir 'state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'datenordner-reparatur.json'), '{"version":1,"zzeit":"x"}')
        $script:TestJournal = @([pscustomobject]@{ id = '20261026-120003-01'; zeit = '2026-10-26T12:00:03'; art = 'ausfuehren'; titel = 'Fake'; status = 'erledigt' })
        foreach ($j in '{}', '{"vorReparatur":false}', '{"vorReparatur":"true"}', '{"vorReparatur":1}') {
            $r = Invoke-TestRoute 'POST' '/api/journal/20261026-120003-01/undo' $j
            $r.status | Should Be 409
            $r.error | Should Match 'vor der Reparatur des Datenordners'
        }
        $script:SysCalls.Confirm | Should Be 0
        $script:SysCalls.Job | Should Be 0
    }
    It 'Undo-Sperre: mit vorReparatur true ergaenzter Dialogtext und Job-Argument, Eintrag nach der Reparatur ohne' {
        $script:Gui.ReadOnly = $false
        $dir = Join-Path $script:TestDir 'state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'datenordner-reparatur.json'), '{"version":1,"zeit":"2026-10-26T12:00:10","konten":[]}')
        $script:TestJournal = @(
            [pscustomobject]@{ id = '20261026-120003-01'; zeit = '2026-10-26T12:00:03'; art = 'ausfuehren'; titel = 'Fake'; status = 'erledigt' },
            [pscustomobject]@{ id = '20261026-130000-01'; zeit = '2026-10-26T13:00:00'; art = 'ausfuehren'; titel = 'Neu'; status = 'erledigt' })
        $r = Invoke-TestRoute 'POST' '/api/journal/20261026-120003-01/undo' '{"vorReparatur":true}'
        $r.status | Should Be 200
        $script:SysCalls.Confirm | Should Be 1
        $script:SysConfirmText | Should Match 'Dieser Eintrag stammt aus der Zeit, in der der Datenordner ungeschützt war\.'
        $script:SysJobArgs.Count | Should Be 6
        $script:SysJobArgs[2] | Should Be '20261026-120003-01'
        $script:SysJobArgs[5] | Should Be $true
        $script:Gui.Jobs = @{}
        $r = Invoke-TestRoute 'POST' '/api/journal/20261026-130000-01/undo' '{}'
        $r.status | Should Be 200
        $script:SysConfirmText | Should Not Match 'ungeschützt'
        $script:SysJobArgs[5] | Should Be $false
    }
    It 'Undo-Sperre (Version 2): nach Id in eintraege, nicht nach Zeit; unlesbar und journalUnlesbar sperren' {
        $script:Gui.ReadOnly = $false
        $dir = Join-Path $script:TestDir 'state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $rep = Join-Path $dir 'datenordner-reparatur.json'
        $script:TestJournal = @(
            [pscustomobject]@{ id = '20261026-120003-01'; zeit = '2099-01-01T00:00:00'; art = 'ausfuehren'; titel = 'Gefaelscht'; status = 'erledigt' },
            [pscustomobject]@{ id = '20261026-130000-01'; zeit = '2026-10-26T13:00:00'; art = 'ausfuehren'; titel = 'Neu'; status = 'erledigt' })
        [IO.File]::WriteAllText($rep, '{"version":2,"zeit":"2026-10-26T12:00:10","konten":[],"eintraege":["20261026-120003-01"],"journalUnlesbar":false}')
        $r = Invoke-TestRoute 'POST' '/api/journal/20261026-120003-01/undo' '{}'
        $r.status | Should Be 409
        $script:Gui.Jobs = @{}
        (Invoke-TestRoute 'POST' '/api/journal/20261026-130000-01/undo' '{}').status | Should Be 200
        $script:Gui.Jobs = @{}
        [IO.File]::WriteAllText($rep, '{"version":2,"zeit":"2026-10-26T12:00:10","konten":[],"eintraege":[],"journalUnlesbar":true}')
        (Invoke-TestRoute 'POST' '/api/journal/20261026-130000-01/undo' '{}').status | Should Be 409
        [IO.File]::WriteAllText($rep, 'kein json')
        (Invoke-TestRoute 'POST' '/api/journal/20261026-130000-01/undo' '{}').status | Should Be 409
    }
    It 'Job-Script undo: PSModulePath-Zeile zuerst, reicht -VorReparaturBestaetigt durch' {
        $s = $script:GuiJobScripts['undo'].ToString()
        $s | Should Match 'param\(\$Root, \$Safety, \$EntryId, \$Force, \$DataRoot, \$VorReparatur\)'
        $z = @($s -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($_ -notmatch '^#') -and ($_ -notmatch '^param\(') })
        $z[0] | Should Match '^\$env:PSModulePath = '
        $script:UJ = $null
        function Undo-PcCheckChange {
            param($Root, $DataRoot, $EntryId, [switch]$Force, [switch]$VorReparaturBestaetigt)
            $h = @{}
            foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }
            $script:UJ = $h
        }
        $tmp = Join-Path $script:TestDir 'leer2.ps1'
        [IO.File]::WriteAllText($tmp, '# leer')
        & $script:GuiJobScripts['undo'] 'R' $tmp 'E1' $false 'D' $true
        $script:UJ.VorReparaturBestaetigt | Should Be $true
        $script:UJ.ContainsKey('Force') | Should Be $false
        & $script:GuiJobScripts['undo'] 'R' $tmp 'E1' $true 'D' $false
        $script:UJ.ContainsKey('VorReparaturBestaetigt') | Should Be $false
        $script:UJ.Force | Should Be $true
    }
}

Describe 'pc-check-gui.ps1: statische Prüfung des Serverstarts' {
    $script:GuiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\pc-check-gui.ps1'), [ref]$null, [ref]$null)
    It 'Initialize-GuiServer bekommt keine Positionsargumente' {
        $cmds = @($script:GuiAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Initialize-GuiServer') }, $true))
        $cmds.Count | Should Be 1
        $nackt = 0
        for ($i = 1; $i -lt $cmds[0].CommandElements.Count; $i++) {
            $el = $cmds[0].CommandElements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { if ($el.Argument) { continue }; if (($i + 1 -lt $cmds[0].CommandElements.Count) -and ($cmds[0].CommandElements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst])) { $i++ } }
            else { $nackt++ }
        }
        $nackt | Should Be 0
    }
    It '$url wird als eigene Anweisung zugewiesen (nicht an die Zeile des Serverstarts angehängt)' {
        $zuw = @($script:GuiAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left -is [System.Management.Automation.Language.VariableExpressionAst]) -and ($n.Left.VariablePath.UserPath -eq 'url') }, $true))
        $zuw.Count | Should BeGreaterThan 0
        # keine Zuweisung steckt als Argument in einem Befehl: ihr Elternknoten ist ein Anweisungsblock, kein CommandAst
        foreach ($z in $zuw) { ($z.Parent -is [System.Management.Automation.Language.CommandAst]) | Should Be $false }
        $cmd = @($script:GuiAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Initialize-GuiServer') }, $true))[0]
        $zuw[0].Extent.StartLineNumber | Should BeGreaterThan $cmd.Extent.EndLineNumber
    }
    It 'Reparatur-Zweig übergibt TempSicher an den Server' {
        $cmd = @($script:GuiAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Initialize-GuiServer') }, $true))[0]
        (@($cmd.CommandElements | Where-Object { ($_ -is [System.Management.Automation.Language.CommandParameterAst]) -and ($_.ParameterName -eq 'TempSicher') }).Count) | Should Be 1
    }
}

Describe 'Test-GuiServerEnde und Heartbeat-Schutz' {
    $jetzt = Get-Date
    function Ende {
        param([bool]$Edge, [bool]$Gesehen = $false, [int]$Anzahl = -1, $Zaehlung = $null, $Heartbeat, [bool]$HbGesehen = $true, [bool]$Busy = $false)
        if ($null -eq $Zaehlung) { $Zaehlung = [datetime]::MinValue }
        Test-GuiServerEnde -EdgeProfil $Edge -EdgeGesehen $Gesehen -EdgeAnzahl $Anzahl -LetzteEdgeZaehlung $Zaehlung `
            -LetzterHeartbeat $Heartbeat -HeartbeatGesehen $HbGesehen -Busy $Busy -Jetzt $jetzt -TimeoutSek 600
    }
    It 'Edge sichtbar, Heartbeat 30 Minuten alt: kein Ende' {
        Ende -Edge $true -Gesehen $true -Anzahl 3 -Zaehlung $jetzt.AddSeconds(-2) -Heartbeat $jetzt.AddMinutes(-30) | Should BeNullOrEmpty
    }
    It 'Edge-Prozesse nach gesehen weg: Fenster geschlossen' {
        Ende -Edge $true -Gesehen $true -Anzahl 0 -Zaehlung $jetzt -Heartbeat $jetzt | Should Be 'Fenster geschlossen'
    }
    It 'Edge nie gesehen und Anzahl 0: kein Ende durch Prozesse' {
        Ende -Edge $true -Gesehen $false -Anzahl 0 -Zaehlung $jetzt -Heartbeat $jetzt | Should BeNullOrEmpty
    }
    It 'Edge nie gesehen (Fenster startete nicht), Zählung gelingt, Heartbeat über Limit: Ende statt endlos weiter' {
        Ende -Edge $true -Gesehen $false -Anzahl 0 -Zaehlung $jetzt -Heartbeat $jetzt.AddSeconds(-700) | Should Be 'Kein Heartbeat mehr'
    }
    It 'Zählung seit über 60 s fehlgeschlagen und Heartbeat über Limit: Ende' {
        Ende -Edge $true -Gesehen $true -Anzahl -1 -Zaehlung $jetzt.AddSeconds(-90) -Heartbeat $jetzt.AddSeconds(-700) | Should Be 'Kein Heartbeat mehr'
    }
    It 'Zählung nie gelungen und Heartbeat über Limit: Ende' {
        Ende -Edge $true -Heartbeat $jetzt.AddSeconds(-700) | Should Be 'Kein Heartbeat mehr'
    }
    It 'Zählung seit über 60 s fehlgeschlagen, Heartbeat aber frisch: kein Ende' {
        Ende -Edge $true -Gesehen $true -Anzahl -1 -Zaehlung $jetzt.AddSeconds(-90) -Heartbeat $jetzt.AddSeconds(-100) | Should BeNullOrEmpty
    }
    It 'Zählung vor 30 s gelungen, Heartbeat über Limit: kein Ende' {
        Ende -Edge $true -Gesehen $true -Anzahl -1 -Zaehlung $jetzt.AddSeconds(-30) -Heartbeat $jetzt.AddSeconds(-700) | Should BeNullOrEmpty
    }
    It 'ohne Edge: Heartbeat über 600 s: Ende' {
        Ende -Edge $false -Heartbeat $jetzt.AddSeconds(-601) | Should Be 'Kein Heartbeat mehr'
    }
    It 'ohne Edge: Heartbeat unter 600 s: kein Ende' {
        Ende -Edge $false -Heartbeat $jetzt.AddSeconds(-599) | Should BeNullOrEmpty
    }
    It 'ohne Edge: vor dem ersten Heartbeat kein Ende' {
        Ende -Edge $false -HbGesehen $false -Heartbeat $jetzt.AddHours(-2) | Should BeNullOrEmpty
    }
    It 'laufende Jobs verhindern jedes Ende' {
        Ende -Edge $true -Gesehen $true -Anzahl 0 -Zaehlung $jetzt -Heartbeat $jetzt.AddHours(-1) -Busy $true | Should BeNullOrEmpty
        Ende -Edge $false -Heartbeat $jetzt.AddHours(-1) -Busy $true | Should BeNullOrEmpty
    }
    It 'Standard-HeartbeatTimeoutSec von Start-GuiServerLoop ist 600' {
        $script:ServerText | Should Match 'param\(\[string\]\$EdgeProfile, \[int\]\$HeartbeatTimeoutSec = 600\)'
    }
    It 'Start-GuiServerLoop nutzt Test-GuiServerEnde' {
        $script:ServerText | Should Match 'Test-GuiServerEnde -EdgeProfil'
    }
    It 'pc-check-gui.ps1 startet Edge mit den drei Schaltern und ohne festes Heartbeat-Limit' {
        $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\pc-check-gui.ps1'), [Text.Encoding]::UTF8)
        $t | Should Match '--disable-background-timer-throttling'
        $t | Should Match '--disable-renderer-backgrounding'
        $t | Should Match '--disable-backgrounding-occluded-windows'
        $t | Should Not Match 'HeartbeatTimeoutSec'
    }
    It 'app.js hat visibilitychange- und focus-Handler für den Heartbeat' {
        $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\app.js'), [Text.Encoding]::UTF8)
        $t | Should Match "addEventListener\('visibilitychange'"
        $t | Should Match "addEventListener\('focus'"
        $t | Should Match 'Morpheus läuft nicht mehr'
    }
}

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
