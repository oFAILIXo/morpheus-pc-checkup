#Requires -Version 5.1
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests fuer gui\lib\EdgeStart.ps1 (Edge ohne Adminrechte, Integritaetspruefung, 2.10, #115, N1) und
# Invoke-GuiEdgePruefung in Server.ps1. Alle Windows-Aufrufe sind ueber $script:MorpheusEdgeImpl ersetzt; echt wird nur
# die Integritaetsstufe des eigenen Prozesses gelesen (reines Lesen). Startet kein Edge, beendet nichts.
# Ausfuehren: Invoke-Pester tests\EdgeStart.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Server.ps1')

$script:EdgeImplEcht = $script:MorpheusEdgeImpl
$script:TestDir = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-edgetest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
$script:Prof = 'C:\Users\Test\AppData\Local\pc-check\edge'

function New-TestProzess {
    param([int]$Id, [string]$Profil = $script:Prof, [string]$Zusatz = '')
    [pscustomobject]@{ ProcessId = $Id; CommandLine = ('"C:\msedge.exe" --user-data-dir="{0}" {1}' -f $Profil, $Zusatz) }
}

Describe 'Get-MorpheusEdgeArgumente' {
    It 'quotet App-Adresse und Profil, enthaelt die Drosselschalter' {
        $a = Get-MorpheusEdgeArgumente -Url 'http://127.0.0.1:41417/#b=abc' -Profil 'C:\Users\A B\edge'
        $a | Should Match '^"--app=http://127\.0\.0\.1:41417/#b=abc" "--user-data-dir=C:\\Users\\A B\\edge" --start-maximized'
        $a | Should Match '--disable-background-timer-throttling'
        $a | Should Match '--disable-renderer-backgrounding'
        $a | Should Match '--disable-backgrounding-occluded-windows'
    }
    It 'wirft bei Anfuehrungszeichen in Adresse oder Profil' {
        { Get-MorpheusEdgeArgumente -Url 'http://x/"' -Profil 'C:\p' } | Should Throw
        { Get-MorpheusEdgeArgumente -Url 'http://x/' -Profil 'C:\p"q' } | Should Throw
    }
}

Describe 'Start-MorpheusEdgeOhneAdmin' {
    AfterEach { $script:MorpheusEdgeImpl = $script:EdgeImplEcht }
    It 'ruft nur den Shell-Start auf (Datei und Argumente) und meldet Erfolg' {
        $script:Aufruf = $null
        $script:MorpheusEdgeImpl = @{ Starten = { param($Datei, $Argumente) $script:Aufruf = @($Datei, $Argumente) } }
        (Start-MorpheusEdgeOhneAdmin -EdgeExe 'C:\Edge\msedge.exe' -Url 'http://127.0.0.1:1/#b=x' -Profil 'C:\p') | Should Be $true
        $script:Aufruf[0] | Should Be 'C:\Edge\msedge.exe'
        $script:Aufruf[1] | Should Match '--app=http://127\.0\.0\.1:1/#b=x'
    }
    It 'Fehler beim Shell-Start: $false, kein Rueckfall (kein weiterer Start)' {
        $script:Zaehler = 0
        $script:MorpheusEdgeImpl = @{ Starten = { param($Datei, $Argumente) $script:Zaehler++; throw 'Desktop weg' } }
        (Start-MorpheusEdgeOhneAdmin -EdgeExe 'C:\Edge\msedge.exe' -Url 'http://127.0.0.1:1/#b=x' -Profil 'C:\p') | Should Be $false
        $script:Zaehler | Should Be 1
    }
}

Describe 'Test-MorpheusEdgeIntegritaet' {
    AfterEach { $script:MorpheusEdgeImpl = $script:EdgeImplEcht }
    BeforeEach {
        # Stufen je Prozess-ID; 9999 = nicht lesbar
        $script:Stufen = @{ 1 = 0x2000; 2 = 0x0; 3 = 0x1000; 4 = 0x3000; 5 = 0x4000; 9999 = $null }
        $script:MorpheusEdgeImpl = @{ Rid = { param($ProcessId) $script:Stufen[[int]$ProcessId] } }
    }
    It 'mittlere Stufe und Sandbox-Kinder (niedrig, nicht vertrauenswuerdig): nicht erhoeht' {
        $r = Test-MorpheusEdgeIntegritaet -Prozesse @((New-TestProzess 1), (New-TestProzess 2 -Zusatz '--type=renderer'), (New-TestProzess 3 -Zusatz '--type=gpu-process')) -Profil $script:Prof
        $r.Geprueft | Should Be 3
        @($r.Erhoeht).Count | Should Be 0
        $r.Unbekannt | Should Be 0
    }
    It 'hohe Stufe und System gelten als erhoeht und werden mit Prozess-ID gemeldet' {
        $r = Test-MorpheusEdgeIntegritaet -Prozesse @((New-TestProzess 1), (New-TestProzess 4), (New-TestProzess 5)) -Profil $script:Prof
        @($r.Erhoeht).Count | Should Be 2
        (@($r.Erhoeht | ForEach-Object { $_.ProcessId }) -join ',') | Should Be '4,5'
        @($r.Erhoeht)[0].Rid | Should Be 0x3000
    }
    It 'Prozesse mit anderem Profil oder ohne Befehlszeile zaehlen nicht (auch nicht, wenn erhoeht)' {
        $r = Test-MorpheusEdgeIntegritaet -Prozesse @((New-TestProzess 4 -Profil 'C:\Users\Test\anderes'), [pscustomobject]@{ ProcessId = 5; CommandLine = $null }, $null) -Profil $script:Prof
        $r.Geprueft | Should Be 0
        @($r.Erhoeht).Count | Should Be 0
    }
    It 'Profilvergleich ohne Beachtung der Gross-/Kleinschreibung' {
        $r = Test-MorpheusEdgeIntegritaet -Prozesse @((New-TestProzess 4 -Profil $script:Prof.ToUpper())) -Profil $script:Prof
        @($r.Erhoeht).Count | Should Be 1
    }
    It 'nicht lesbarer Prozess: unbekannt, nie als erhoeht geraten' {
        $r = Test-MorpheusEdgeIntegritaet -Prozesse @((New-TestProzess 9999), (New-TestProzess 1)) -Profil $script:Prof
        $r.Unbekannt | Should Be 1
        $r.Geprueft | Should Be 2
        @($r.Erhoeht).Count | Should Be 0
    }
    It 'keine Prozesse (null oder leer): leeres Ergebnis' {
        (Test-MorpheusEdgeIntegritaet -Prozesse $null -Profil $script:Prof).Geprueft | Should Be 0
        (Test-MorpheusEdgeIntegritaet -Prozesse @() -Profil $script:Prof).Geprueft | Should Be 0
    }
}

Describe 'Invoke-GuiEdgePruefung (Server)' {
    AfterEach { $script:MorpheusEdgeImpl = $script:EdgeImplEcht }
    BeforeEach {
        $script:Gui = @{ DataRoot = $script:TestDir; ReadOnly = $false; ReadOnlyReason = '' }
        $script:Beendet = New-Object System.Collections.Generic.List[int]
        $script:Stufen = @{ 1 = 0x2000; 2 = 0x0; 4 = 0x3000; 9999 = $null }
        $script:MorpheusEdgeImpl = @{
            Rid     = { param($ProcessId) $script:Stufen[[int]$ProcessId] }
            Beenden = { param($ProcessId) $script:Beendet.Add([int]$ProcessId) }
        }
    }
    It 'alles mittel/niedrig: nichts beenden, kein Nur-Lesen' {
        Invoke-GuiEdgePruefung -Prozesse @((New-TestProzess 1), (New-TestProzess 2)) -Profil $script:Prof
        $script:Beendet.Count | Should Be 0
        $script:Gui.ReadOnly | Should Be $false
    }
    It 'erhoehter Prozess: beendet nur diesen, Nur-Lesen mit Grund (Prozess-ID)' {
        Invoke-GuiEdgePruefung -Prozesse @((New-TestProzess 1), (New-TestProzess 4)) -Profil $script:Prof
        ($script:Beendet -join ',') | Should Be '4'
        $script:Gui.ReadOnly | Should Be $true
        $script:Gui.ReadOnlyReason | Should Match 'Adminrechten \(Prozess 4\)'
    }
    It 'Beenden schlaegt fehl: Nur-Lesen gilt trotzdem' {
        $script:MorpheusEdgeImpl.Beenden = { param($ProcessId) throw 'Zugriff verweigert' }
        Invoke-GuiEdgePruefung -Prozesse @((New-TestProzess 4)) -Profil $script:Prof
        $script:Gui.ReadOnly | Should Be $true
    }
    It 'nicht lesbarer Prozess: nur einmal protokolliert, kein Nur-Lesen' {
        Invoke-GuiEdgePruefung -Prozesse @((New-TestProzess 9999)) -Profil $script:Prof
        Invoke-GuiEdgePruefung -Prozesse @((New-TestProzess 9999)) -Profil $script:Prof
        $script:Gui.ReadOnly | Should Be $false
        $script:Gui.EdgeUnbekanntGemeldet | Should Be $true
        $log = Get-Content -LiteralPath (Join-Path $script:TestDir 'state\gui.log') -Raw
        ([regex]::Matches($log, 'Edge-Integrit')).Count | Should Be 1
    }
}

Describe 'MorpheusProzessRidLesen (echter Windows-Aufruf, nur lesend)' {
    It 'eigener Prozess: mittlere (oder bei Adminlauf hohe) Stufe' {
        $r = MorpheusProzessRidLesen -ProcessId $PID
        ($r -eq 0x2000) -or ($r -eq 0x3000) | Should Be $true
    }
    It 'nicht vorhandene Prozess-ID: $null' {
        MorpheusProzessRidLesen -ProcessId 2147483000 | Should Be $null
    }
}

Describe 'Start in pc-check-gui.ps1 (statisch)' {
    $script:GuiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\pc-check-gui.ps1'), [ref]$null, [ref]$null)
    It 'Start-Process fuer Edge steht nur im Zweig ohne Adminrechte, mit Adminrechten startet Start-MorpheusEdgeOhneAdmin' {
        $edgeStarts = @($script:GuiAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Start-Process') -and ($n.Extent.Text -match '\$edgeExe') }, $true))
        $edgeStarts.Count | Should Be 1
        $if = $null
        for ($p = $edgeStarts[0].Parent; $p; $p = $p.Parent) {
            if (($p -is [System.Management.Automation.Language.IfStatementAst]) -and ($p.Clauses[0].Item1.Extent.Text -eq '$isAdmin')) { $if = $p; break }
        }
        $if | Should Not BeNullOrEmpty
        # Start-Process liegt im else-Zweig, der Adminzweig ruft die Funktion
        $if.ElseClause.Extent.Text | Should Match 'Start-Process'
        $if.Clauses[0].Item2.Extent.Text | Should Match 'Start-MorpheusEdgeOhneAdmin'
        $if.Clauses[0].Item2.Extent.Text | Should Not Match 'Start-Process'
    }
    It 'EdgeStart.ps1 startet nie selbst einen Prozess (kein Start-Process, kein Process.Start)' {
        $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\EdgeStart.ps1'), [Text.Encoding]::UTF8)
        $code = (($t -replace '(?s)<#.*?#>', '') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should Not Match 'Start-Process|\[Diagnostics\.Process\]::Start|New-Object.*ProcessStartInfo|Add-Type'
    }
}

Remove-Item -LiteralPath $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
