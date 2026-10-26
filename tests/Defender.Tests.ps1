#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Defender.ps1. Ruft nie die echten Defender-Aktionen auf:
# alle Einträge von $script:MorpheusDefenderImpl sind Attrappen.
# Ausführen: Invoke-Pester tests\Defender.Tests.ps1

$script:DefenderFile = Join-Path $PSScriptRoot '..\gui\lib\Defender.ps1'
. $script:DefenderFile

# Setzt alle Attrappen und zählt die Aufrufe in $script:Calls
function Set-FakeDefender {
    param([switch]$ThrowStatus, [switch]$ThrowSignaturen, [switch]$ThrowScan, $Funde = @())
    $script:Calls = @{ Status = 0; Signaturen = 0; Schnellscan = 0; Datei = 0; Funde = 0; Offline = 0 }
    $script:FundeSeit = $null
    $script:FakeFunde = $Funde
    $script:SigVersion = '1.1.1'
    $script:FakeThrowStatus = [bool]$ThrowStatus
    $script:MorpheusDefenderImpl = @{
        Status = {
            $script:Calls.Status++
            if ($script:FakeThrowStatus) { throw 'Status kaputt' }
            [pscustomobject]@{
                AMRunningMode                = 'Normal'
                AntivirusSignatureLastUpdated = [datetime]'2026-10-20T08:15:30'
                AntivirusSignatureVersion    = $script:SigVersion
                AntivirusSignatureAge        = 2
                QuickScanEndTime             = [datetime]'2026-10-18T21:00:05'
                QuickScanAge                 = 4
                RealTimeProtectionEnabled    = $true
            }
        }
        Signaturen = { $script:Calls.Signaturen++; if ($script:FakeThrowSig) { throw 'Kein Netz' } ; 'Rauschen' }
        Schnellscan = { $script:Calls.Schnellscan++; if ($script:FakeThrowScan) { throw 'Scan abgebrochen' } }
        Datei = { param($Pfad) $script:Calls.Datei++; $script:DateiPfad = $Pfad }
        Funde = { param($Seit) $script:Calls.Funde++; $script:FundeSeit = $Seit; $script:FakeFunde }
        Offline = { $script:Calls.Offline++ }
    }
    $script:FakeThrowSig = [bool]$ThrowSignaturen
    $script:FakeThrowScan = [bool]$ThrowScan
}

Describe 'Defender.ps1: Datei' {
    It 'hat UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:DefenderFile)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'lässt sich fehlerfrei parsen' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:DefenderFile).Path, [ref]$null, [ref]$errors)
        @($errors).Count | Should Be 0
    }
    It 'verwendet kein Add-Type' {
        (Get-Content -LiteralPath $script:DefenderFile -Raw) | Should Not Match 'Add-Type'
    }
    It 'enthält Start-MpWDOScan nur im Impl-Block' {
        $lines = @(Get-Content -LiteralPath $script:DefenderFile | Where-Object { $_ -match 'Start-MpWDOScan' })
        $lines.Count | Should Be 1
        $lines[0] | Should Match 'Offline\s*=\s*\{'
    }
    It 'enthält Update-MpSignature und Start-MpScan nur im Impl-Block' {
        $text = Get-Content -LiteralPath $script:DefenderFile
        @($text | Where-Object { $_ -match 'Update-MpSignature' }).Count | Should Be 1
        @($text | Where-Object { $_ -match 'Start-MpScan' }).Count | Should Be 2
    }
    It 'bringt Standard-Impl mit allen sechs Einträgen' {
        foreach ($k in 'Status', 'Signaturen', 'Schnellscan', 'Datei', 'Funde', 'Offline') {
            # frisch laden, ohne die Attrappen der anderen Tests zu berühren
            $impl = & { $script:MorpheusDefenderImpl = $null; . $script:DefenderFile; $script:MorpheusDefenderImpl }
            ($impl[$k] -is [scriptblock]) | Should Be $true
        }
    }
}

Describe 'Get-MorpheusDefenderStand' {
    It 'liefert alle Felder mit ISO-Datum' {
        Set-FakeDefender
        $s = Get-MorpheusDefenderStand
        $s.Keys -join ',' | Should Be 'modus,signaturen,signaturVersion,signaturAlterTage,schnellscan,schnellscanAlterTage,echtzeit'
        $s.modus | Should Be 'Normal'
        $s.signaturen | Should Be '2026-10-20T08:15:30'
        $s.signaturVersion | Should Be '1.1.1'
        $s.signaturAlterTage | Should Be 2
        $s.schnellscan | Should Be '2026-10-18T21:00:05'
        $s.schnellscanAlterTage | Should Be 4
        $s.echtzeit | Should Be $true
    }
    It 'setzt fehlende Werte auf $null' {
        Set-FakeDefender
        $script:MorpheusDefenderImpl.Status = { [pscustomobject]@{ AMRunningMode = 'Normal' } }
        $s = Get-MorpheusDefenderStand
        $s.signaturen | Should BeNullOrEmpty
        $s.schnellscan | Should BeNullOrEmpty
        $s.signaturVersion | Should BeNullOrEmpty
        $s.Contains('schnellscan') | Should Be $true
    }
    It 'liefert bei Ausnahme nur fehler' {
        Set-FakeDefender -ThrowStatus
        $s = Get-MorpheusDefenderStand
        $s.Keys -join ',' | Should Be 'fehler'
        $s.fehler | Should Be 'Status kaputt'
    }
}

Describe 'Invoke-MorpheusDefenderAktion' {
    It 'signaturen ruft nur Signaturen' {
        Set-FakeDefender
        $r = Invoke-MorpheusDefenderAktion -Art 'signaturen' 6>$null
        $script:Calls.Signaturen | Should Be 1
        $script:Calls.Schnellscan | Should Be 0
        $script:Calls.Offline | Should Be 0
        $r.art | Should Be 'signaturen'
    }
    It 'schnellscan ruft nur Schnellscan' {
        Set-FakeDefender
        $r = Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null
        $script:Calls.Schnellscan | Should Be 1
        $script:Calls.Signaturen | Should Be 0
        $script:Calls.Offline | Should Be 0
        $r.art | Should Be 'schnellscan'
    }
    foreach ($bad in 'vollscan', 'Signaturen', 'SCHNELLSCAN', '') {
        It "wirft bei ungültiger Art '$bad' und ruft nichts auf" {
            Set-FakeDefender
            { Invoke-MorpheusDefenderAktion -Art $bad } | Should Throw
            ($script:Calls.Values | Measure-Object -Sum).Sum | Should Be 0
        }
    }
    It 'ausgabe ist genau ein Objekt mit allen Feldern' {
        Set-FakeDefender
        $out = @(Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null)
        $out.Count | Should Be 1
        ($out[0].PSObject.Properties.Name -join ',') | Should Be 'art,pfad,vorher,nachher,funde,dauerSek,meldung'
        $out[0].vorher.signaturVersion | Should Be '1.1.1'
        $out[0].nachher.modus | Should Be 'Normal'
        ($out[0].dauerSek -ge 0) | Should Be $true
    }
    It 'schreibt Fortschritt als Informationen mit Zeitstempel' {
        Set-FakeDefender
        $info = @()
        $null = Invoke-MorpheusDefenderAktion -Art 'signaturen' -InformationVariable info 6>$null
        ($info | Where-Object { "$_" -match '^\[\d\d:\d\d:\d\d\] Signaturen werden aktualisiert' }).Count | Should Be 1
        Set-FakeDefender
        $info = @()
        $null = Invoke-MorpheusDefenderAktion -Art 'schnellscan' -InformationVariable info 6>$null
        ($info | Where-Object { "$_" -match 'Schnellscan läuft' }).Count | Should Be 1
    }
    It 'fragt Funde mit der Startzeit ab und bildet sie ab' {
        $f = @(
            [pscustomobject]@{ zeit = [datetime]'2026-10-25T10:00:00'; name = 'Trojan:Test/A'; aktion = 'In Quarantäne'; erfolg = $true; dateien = @('C:\a.exe', 'C:\b.exe', 'C:\c.exe', 'C:\d.exe') },
            [pscustomobject]@{ zeit = [datetime]'2026-10-25T10:01:00'; name = 'Eicar'; aktion = 'Keine Aktion'; erfolg = $false; dateien = 'C:\x.txt' }
        )
        Set-FakeDefender -Funde $f
        $vor = Get-Date
        $r = Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null
        $script:Calls.Funde | Should Be 1
        ($script:FundeSeit -is [datetime]) | Should Be $true
        ($script:FundeSeit -ge $vor.AddSeconds(-1)) | Should Be $true
        ($script:FundeSeit -le (Get-Date)) | Should Be $true
        @($r.funde).Count | Should Be 2
        $r.funde[0].zeit | Should Be '2026-10-25T10:00:00'
        $r.funde[0].name | Should Be 'Trojan:Test/A'
        $r.funde[0].aktion | Should Be 'In Quarantäne'
        $r.funde[0].erfolg | Should Be $true
        $r.funde[0].dateien | Should Be 'C:\a.exe; C:\b.exe; C:\c.exe'
        $r.funde[1].dateien | Should Be 'C:\x.txt'
        $r.funde[1].erfolg | Should Be $false
        $r.meldung | Should Match 'Windows-Sicherheit'
        $r.meldung | Should Match 'Schutzverlauf'
    }
    It 'liefert ohne Funde ein leeres Array und keine Windows-Sicherheit-Meldung' {
        Set-FakeDefender
        $r = Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null
        @($r.funde).Count | Should Be 0
        $r.meldung | Should Not Match 'Windows-Sicherheit'
    }
    It 'meldet bei unveränderten Signaturen "schon aktuell"' {
        Set-FakeDefender
        $r = Invoke-MorpheusDefenderAktion -Art 'signaturen' 6>$null
        $r.meldung | Should Be 'Die Signaturen waren schon aktuell.'
    }
    It 'meldet bei neuer Signaturversion die Aktualisierung' {
        Set-FakeDefender
        $script:MorpheusDefenderImpl.Signaturen = { $script:Calls.Signaturen++; $script:SigVersion = '1.2.2' }
        $r = Invoke-MorpheusDefenderAktion -Art 'signaturen' 6>$null
        $r.vorher.signaturVersion | Should Be '1.1.1'
        $r.nachher.signaturVersion | Should Be '1.2.2'
        $r.meldung | Should Match 'aktualisiert'
        $r.meldung | Should Match '1\.2\.2'
    }
    It 'wirft bei Fehler der Signatur-Aktualisierung mit deutscher Meldung' {
        Set-FakeDefender -ThrowSignaturen
        $msg = $null
        try { $null = Invoke-MorpheusDefenderAktion -Art 'signaturen' 6>$null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'Signaturen konnten nicht aktualisiert werden'
        $msg | Should Match 'Kein Netz'
    }
    It 'wirft bei Fehler des Schnellscans' {
        Set-FakeDefender -ThrowScan
        $msg = $null
        try { $null = Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'Schnellscan'
        $msg | Should Match 'Scan abgebrochen'
    }
    It 'läuft auch bei nicht lesbarem Status weiter (fehler im Stand)' {
        Set-FakeDefender -ThrowStatus
        $r = Invoke-MorpheusDefenderAktion -Art 'schnellscan' 6>$null
        $r.vorher.fehler | Should Be 'Status kaputt'
        $script:Calls.Schnellscan | Should Be 1
    }
}

Describe 'Start-MorpheusDefenderOffline' {
    It 'ruft nur Offline auf und gibt nichts aus' {
        Set-FakeDefender
        $out = @(Start-MorpheusDefenderOffline 6>$null)
        $out.Count | Should Be 0
        $script:Calls.Offline | Should Be 1
        $script:Calls.Signaturen | Should Be 0
        $script:Calls.Schnellscan | Should Be 0
        $script:Calls.Status | Should Be 0
    }
    It 'reicht einen Fehler von Offline weiter' {
        Set-FakeDefender
        $script:MorpheusDefenderImpl.Offline = { throw 'nicht möglich' }
        { Start-MorpheusDefenderOffline 6>$null } | Should Throw
    }
}

Describe 'Invoke-MorpheusDefenderAktion: datei' {
    BeforeEach { $script:DateiTest = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-deftest-' + [guid]::NewGuid().ToString('N') + '.sys'); [IO.File]::WriteAllText($script:DateiTest, 'x') }
    AfterEach { Remove-Item -LiteralPath $script:DateiTest -Force -ErrorAction SilentlyContinue }
    It 'prueft die Datei ueber die Attrappe und liefert pfad und Meldung' {
        Set-FakeDefender
        $r = Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad $script:DateiTest 6>$null
        $script:Calls.Datei | Should Be 1
        $script:DateiPfad | Should Be $script:DateiTest
        $script:Calls.Schnellscan | Should Be 0
        $r.art | Should Be 'datei'
        $r.pfad | Should Be $script:DateiTest
        $r.meldung | Should Match 'nichts gefunden'
        $r.meldung | Should Match 'Defender-Ausnahme'
    }
    It 'zeigt nur Funde dieser Datei (auch mit file:_-Praefix) und markiert fruehere' {
        $neu = [datetime]::Now.AddMinutes(1)
        $f = @(
            [pscustomobject]@{ zeit = $neu; name = 'Neu'; aktion = 'Blockiert'; erfolg = $true; dateien = @('file:_' + $script:DateiTest.ToUpper()) },
            [pscustomobject]@{ zeit = [datetime]'2025-01-01T10:00:00'; name = 'Alt'; aktion = 'In Quarantäne'; erfolg = $true; dateien = @('file:_' + $script:DateiTest) },
            [pscustomobject]@{ zeit = $neu; name = 'Andere'; aktion = 'Blockiert'; erfolg = $true; dateien = @('C:\andere\datei.exe') })
        Set-FakeDefender -Funde $f
        $r = Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad $script:DateiTest 6>$null
        $script:FundeSeit | Should Be ([datetime]::MinValue)
        @($r.funde).Count | Should Be 2
        $r.funde[0].name | Should Be 'Neu'
        $r.funde[0].frueher | Should Be $false
        $r.funde[1].name | Should Be 'Alt'
        $r.funde[1].frueher | Should Be $true
        (@($r.funde | Where-Object { $_.name -eq 'Andere' })).Count | Should Be 0
    }
    It 'nur Funde anderer Dateien: Meldung nichts gefunden' {
        Set-FakeDefender -Funde @([pscustomobject]@{ zeit = (Get-Date).AddMinutes(1); name = 'Andere'; aktion = 'Blockiert'; erfolg = $true; dateien = @('C:\andere\datei.exe') })
        $r = Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad $script:DateiTest 6>$null
        @($r.funde).Count | Should Be 0
        $r.meldung | Should Match 'nichts gefunden'
    }
    It 'Pfad ist Pflicht bei datei und muss existieren' {
        Set-FakeDefender
        { Invoke-MorpheusDefenderAktion -Art 'datei' 6>$null } | Should Throw
        { Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad 'C:\gibt\es\nicht.sys' 6>$null } | Should Throw
        $script:Calls.Datei | Should Be 0
    }
    It 'Pfad ist bei anderen Aufgaben verboten' {
        Set-FakeDefender
        { Invoke-MorpheusDefenderAktion -Art 'schnellscan' -Pfad $script:DateiTest 6>$null } | Should Throw
        $script:Calls.Schnellscan | Should Be 0
    }
    It 'Fehler der Pruefung werden gemeldet' {
        Set-FakeDefender
        $script:MorpheusDefenderImpl.Datei = { param($Pfad) throw 'kaputt' }
        { Invoke-MorpheusDefenderAktion -Art 'datei' -Pfad $script:DateiTest 6>$null } | Should Throw
    }
}
