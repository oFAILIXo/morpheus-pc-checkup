#Requires -Version 5.1
# Pester-3.4-Tests fuer gui\lib\WartungAuswertung.ps1. Reine Funktionen, keine Prozesse; Beispielausgaben in tests\fixtures\wartung.
# Ausfuehren: Invoke-Pester tests\WartungAuswertung.Tests.ps1

$script:AwDatei = Join-Path $PSScriptRoot '..\gui\lib\WartungAuswertung.ps1'
$script:Fix = Join-Path $PSScriptRoot 'fixtures\wartung'
. $script:AwDatei

function Get-WFix {
    param([string]$Name)
    [IO.File]::ReadAllText((Join-Path $script:Fix ($Name + '.txt')), [Text.Encoding]::UTF8)
}
function Get-WZ {
    param([string]$Name, [object]$Exit = 0)
    $id = ($Name -split '\.(?:de|en)\.')[0]
    if ($Name -match '^trim\.') { $id = 'trim' }
    Get-MorpheusWartungZusammenfassung -Werkzeug $id -Text (Get-WFix $Name) -ExitCode $Exit
}

Describe 'WartungAuswertung.ps1 Datei' {
    It 'hat ein UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:AwDatei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'parst ohne Fehler' {
        $err = $null; $tok = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:AwDatei, [ref]$tok, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'enthaelt kein Add-Type und startet keine Prozesse' {
        $err = $null; $tok = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:AwDatei, [ref]$tok, [ref]$err)
        $cmds = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and (@('Add-Type', 'Start-Process', 'Invoke-Expression', 'Invoke-WebRequest') -contains $n.GetCommandName()) }, $true)
        @($cmds).Count | Should Be 0
    }
    It 'alle Fixtures haben BOM und CRLF' {
        $files = @(Get-ChildItem (Join-Path $script:Fix '*.txt'))
        $files.Count | Should BeGreaterThan 40
        foreach ($f in $files) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
            (([Text.Encoding]::UTF8.GetString($b)) -match "`r`n") | Should Be $true
        }
    }
}

Describe 'Format-MorpheusWartungZeile' {
    It '$null und leer ergeben Leerstring' {
        Format-MorpheusWartungZeile -Text $null | Should Be ''
        Format-MorpheusWartungZeile -Text '' | Should Be ''
    }
    It 'entfernt Steuerzeichen ausser Tab' {
        $t = 'A' + [char]0 + 'B' + [char]7 + 'C' + [char]27 + '[31mD' + [char]0x7F + "`tE" + "`r`n"
        Format-MorpheusWartungZeile -Text $t | Should Be "ABC[31mD`tE"
    }
    It 'entfernt Bidi- und Zeilentrenner-Zeichen' {
        $t = 'gut' + [char]0x202E + 'schlecht' + [char]0x2066 + 'x' + [char]0x2069 + [char]0x2028 + [char]0x2029 + [char]0x202A + 'y'
        Format-MorpheusWartungZeile -Text $t | Should Be 'gutschlechtxy'
    }
    It 'trimmt Leerraum' {
        Format-MorpheusWartungZeile -Text "   hallo   " | Should Be 'hallo'
    }
    It 'kuerzt auf 500 Zeichen mit Auslassungszeichen' {
        $r = Format-MorpheusWartungZeile -Text ('a' * 800)
        $r.Length | Should Be 500
        $r.EndsWith([string][char]0x2026) | Should Be $true
    }
    It 'laesst 500 Zeichen unveraendert' {
        (Format-MorpheusWartungZeile -Text ('b' * 500)).Length | Should Be 500
        (Format-MorpheusWartungZeile -Text ('b' * 500)).EndsWith([string][char]0x2026) | Should Be $false
    }
    It 'laesst Umlaute stehen' {
        Format-MorpheusWartungZeile -Text 'Überprüfung läuft' | Should Be 'Überprüfung läuft'
    }
}

Describe 'Get-MorpheusWartungFortschritt' {
    $treffer = @(
        @('[====       25.0%                ]', 25.0),
        @('[==========================100.0%==========================]', 100.0),
        @('[                           0.1%                           ]', 0.1),
        @('[==========================50.0%                           ]', 50.0),
        @('Verification 45% complete.', 45.0),
        @('Verification 100% complete.', 100.0),
        @('Überprüfung 45 % abgeschlossen.', 45.0),
        @('Stage 1: Examining basic file system structure ... 30 percent complete', 30.0),
        @('Stufe 2: Dateinamenverknüpfung wird überprüft ... 30 Prozent abgeschlossen', 30.0),
        @('  30 percent complete. (118200 of 421312 index entries processed)', 30.0),
        @('Pass 1: 30% complete', 30.0),
        @('Defragmentierung: 30 % abgeschlossen', 30.0),
        @('Fortschritt 72 %', 72.0),
        @('Progress: 123 of 421312 done; Stage:  29%; Total:  14%; ETA:   0:00:20', 14.0),
        @('Progress: 123 of 421312 done; Stage:  29%; ETA:   0:00:20', 29.0),
        @('Fortschritt: 123 von 421312 erledigt; Phase:  29 %; Gesamt:  14 %; ETA:   0:00:20', 14.0),
        @('Fortschritt: 123 von 421312 erledigt; Phase:  29 %; ETA:   0:00:20', 29.0)
    )
    foreach ($t in $treffer) {
        It ('erkennt: ' + $t[0]) {
            Get-MorpheusWartungFortschritt -Zeile $t[0] | Should Be $t[1]
        }
    }
    $nicht = @(
        'Freigebbare Pakete : 2',
        'Number of Reclaimable Packages : 2',
        'Actual Size of Component Store : 8.27 GB',
        'Tatsächliche Größe des Komponentenspeichers : 8,27 GB',
        'Vom Windows-Explorer gemeldete Größe des Komponentenspeichers : 8,55 GB',
        'Der Vorgang wurde erfolgreich beendet.',
        'Version: 10.0.26100.1',
        '311040816 KB in 301245 Dateien',
        '',
        '   ',
        'Es wurde keine Komponentenspeicherbeschädigung erkannt.',
        'Viel Text, der ein Prozentzeichen enthält und deshalb keine Fortschrittszeile sein soll, denn er ist viel zu lang für eine Anzeige 50 % mehr.',
        'Wert 250 %'
    )
    foreach ($z in $nicht) {
        It ('erkennt nicht: ' + $z) {
            Get-MorpheusWartungFortschritt -Zeile $z | Should BeNullOrEmpty
        }
    }
    It '$null ergibt $null' { Get-MorpheusWartungFortschritt -Zeile $null | Should BeNullOrEmpty }
}

Describe 'Get-MorpheusWartungZusammenfassung Fixtures' {
    # Name, erwartetes Ergebnis, Teil von text, Teil von empfehlung ($null = keine)
    $faelle = @(
        @('dism.checkhealth.en.ok', 'ok', 'Keine Beschädigung', $null),
        @('dism.checkhealth.de.ok', 'ok', 'Keine Beschädigung', $null),
        @('dism.checkhealth.en.reparierbar', 'reparierbar', 'aber reparieren', 'RestoreHealth'),
        @('dism.checkhealth.de.reparierbar', 'reparierbar', 'aber reparieren', 'RestoreHealth'),
        @('dism.scanhealth.en.ok', 'ok', 'Keine Beschädigung', $null),
        @('dism.scanhealth.de.ok', 'ok', 'Keine Beschädigung', $null),
        @('dism.scanhealth.en.reparierbar', 'reparierbar', 'aber reparieren', 'SFC'),
        @('dism.scanhealth.de.reparierbar', 'reparierbar', 'aber reparieren', 'SFC'),
        @('dism.scanhealth.en.nicht-reparierbar', 'fehler', 'nicht reparieren', 'Reparatur-Upgrade'),
        @('dism.scanhealth.de.nicht-reparierbar', 'fehler', 'nicht reparieren', 'Reparatur-Upgrade'),
        @('dism.restorehealth.en.ok', 'ok', 'ohne Fehler abgeschlossen', 'SFC'),
        @('dism.restorehealth.de.ok', 'ok', 'ohne Fehler abgeschlossen', 'SFC'),
        @('dism.restorehealth.en.0x800f081f', 'fehler', 'Quelldateien', 'Windows Update'),
        @('dism.restorehealth.de.0x800f081f', 'fehler', 'Quelldateien', 'Windows Update'),
        @('sfc.scannow.en.ok', 'ok', 'keine Beschädigung', $null),
        @('sfc.scannow.de.ok', 'ok', 'keine Beschädigung', $null),
        @('sfc.scannow.en.repariert', 'repariert', 'gefunden und repariert', 'neu starten'),
        @('sfc.scannow.de.repariert', 'repariert', 'gefunden und repariert', 'neu starten'),
        @('sfc.scannow.en.teilweise', 'problem', 'einige nicht reparieren', 'RestoreHealth'),
        @('sfc.scannow.de.teilweise', 'problem', 'einige nicht reparieren', 'RestoreHealth'),
        @('sfc.scannow.en.ausstehend', 'problem', 'Neustart', 'neu starten'),
        @('sfc.scannow.de.ausstehend', 'problem', 'Neustart', 'neu starten'),
        @('sfc.scannow.en.fehler', 'fehler', 'SFC konnte nicht arbeiten', 'DISM'),
        @('sfc.scannow.de.fehler', 'fehler', 'SFC konnte nicht arbeiten', 'DISM'),
        @('dism.cleanup.en.ok', 'ok', 'bereinigt', $null),
        @('dism.cleanup.de.ok', 'ok', 'bereinigt', $null),
        @('chkdsk.scan.en.ok', 'ok', 'keine Probleme', $null),
        @('chkdsk.scan.de.ok', 'ok', 'keine Probleme', $null),
        @('chkdsk.scan.en.ok-neu', 'ok', 'keine Probleme', $null),
        @('chkdsk.scan.de.ok-neu', 'ok', 'keine Probleme', $null),
        @('chkdsk.scan.en.probleme', 'problem', 'Probleme am Dateisystem', 'Datensicherung'),
        @('chkdsk.scan.de.probleme', 'problem', 'Probleme am Dateisystem', 'Datensicherung'),
        @('dns.flush.en.ok', 'ok', 'DNS', $null),
        @('dns.flush.de.ok', 'ok', 'DNS', $null),
        @('zeit.resync.en.ok', 'ok', 'Uhrzeit', $null),
        @('zeit.resync.de.ok', 'ok', 'Uhrzeit', $null),
        @('zeit.resync.en.keine-zeitdaten', 'problem', 'keine Zeitdaten', 'Internet'),
        @('zeit.resync.de.keine-zeitdaten', 'problem', 'keine Zeitdaten', 'Internet'),
        @('trim.en.ok', 'ok', 'TRIM', $null),
        @('trim.de.ok', 'ok', 'TRIM', $null),
        @('powercfg.energy.en.ok', 'ok', 'Energiebericht', 'Bericht'),
        @('powercfg.energy.de.ok', 'ok', 'Energiebericht', 'Bericht'),
        @('powercfg.akku.en.ohne-akku', 'problem', 'keinen Akku', 'Notebooks'),
        @('powercfg.akku.de.ohne-akku', 'problem', 'keinen Akku', 'Notebooks'),
        @('powercfg.schlaf.en.nicht-unterstuetzt', 'problem', 'Modern Standby', 'Notebooks'),
        @('powercfg.schlaf.de.nicht-unterstuetzt', 'problem', 'Modern Standby', 'Notebooks')
    )
    foreach ($f in $faelle) {
        $name = $f[0]; $erg = $f[1]; $teil = $f[2]; $emp = $f[3]
        It ($name + ' -> ' + $erg) {
            $z = Get-WZ -Name $name -Exit 0
            $z.ergebnis | Should Be $erg
            $z.text.Contains($teil) | Should Be $true
            if ($emp) { ([string]$z.empfehlung).Contains($emp) | Should Be $true } else { $z.empfehlung | Should BeNullOrEmpty }
            $z.PSObject.Properties.Name -join ',' | Should Be 'ergebnis,text,empfehlung,details'
        }
    }
    It 'alle Fixtures sind in der Tabelle abgedeckt (ausser analyze)' {
        $namen = @($faelle | ForEach-Object { $_[0] })
        $fehlt = @(Get-ChildItem (Join-Path $script:Fix '*.txt') | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Where-Object { ($namen -notcontains $_) -and ($_ -notlike 'dism.analyze.*') })
        ($fehlt -join ',') | Should Be ''
    }
}

Describe 'Get-MorpheusWartungZusammenfassung Einzelheiten' {
    It 'checkhealth: Fehlercode 0x800f081f in der Ausgabe zaehlt als Fehler' {
        $z = Get-WZ 'dism.restorehealth.en.0x800f081f' 1
        $z.ergebnis | Should Be 'fehler'
        ($z.details -join '|').Contains('0x800f081f') | Should Be $true
    }
    It 'DISM-Fehlercodes werden erklaert' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.restorehealth' -Text "Error: 0x800f0906`r`nThe source files could not be downloaded." -ExitCode (-2146498298)
        $z.ergebnis | Should Be 'fehler'; $z.text.Contains('herunterladen') | Should Be $true
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.restorehealth' -Text 'Fehler: 0x800f0907' -ExitCode 1
        $z.text.Contains('Gruppenrichtlinie') | Should Be $true
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.checkhealth' -Text "Error: 87`r`nThe cleanup-image option is unknown." -ExitCode 87
        $z.text.Contains('87') | Should Be $true
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.scanhealth' -Text 'Error: 0x800f0950' -ExitCode 1
        $z.ergebnis | Should Be 'fehler'; $z.text.Contains('0x800f0950') | Should Be $true
    }
    It 'RestoreHealth: ausdrueckliche Reparatur ergibt repariert' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.restorehealth' -Text 'The component store corruption was repaired. The restore operation completed successfully.' -ExitCode 0
        $z.ergebnis | Should Be 'repariert'
    }
    It 'SFC: Satz ueber mehrere Zeilen mit vielen Leerzeichen und Grossschreibung' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text "WINDOWS Resource   Protection found corrupt files and `r`n  SUCCESSFULLY  repaired`r`nthem." -ExitCode 0
        $z.ergebnis | Should Be 'repariert'
    }
    It 'SFC: repariert und zusaetzlich Neustart erwaehnt ist repariert (englisch)' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text "Windows Resource Protection found corrupt files and successfully repaired them.`r`nA system repair is pending which requires reboot to complete. Restart Windows and run sfc again." -ExitCode 0
        $z.ergebnis | Should Be 'repariert'
        $z.empfehlung | Should Match 'neu starten'
    }
    It 'SFC: repariert und zusaetzlich Neustart erwaehnt ist repariert (deutsch)' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text "Der Windows-Ressourcenschutz hat beschädigte Dateien gefunden und erfolgreich repariert.`r`nEine Systemreparatur aus einem früheren Vorgang steht aus. Ein Neustart ist erforderlich." -ExitCode 0
        $z.ergebnis | Should Be 'repariert'
    }
    It 'SFC: nur Reparatur ausstehend ohne repariert bleibt problem' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text 'There is a system repair pending which requires reboot to complete.' -ExitCode 0).ergebnis | Should Be 'problem'
    }
    It 'chkdsk neues Format: Fixtures enthalten viele erkannte Fortschrittszeilen, Gesamtwert steigt' {
        foreach ($n in 'chkdsk.scan.en.ok-neu', 'chkdsk.scan.de.ok-neu') {
            $w = @((Get-WFix $n) -split "`r?`n" | ForEach-Object { Get-MorpheusWartungFortschritt -Zeile $_ } | Where-Object { $null -ne $_ })
            $w.Count | Should BeGreaterThan 15
            $w[0] | Should Be 4
            $w[$w.Count - 1] | Should Be 98
        }
    }
    It 'SFC: Satz ohne Schlusspunkt' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text 'Der Windows-Ressourcenschutz hat keine Integritätsverletzungen gefunden' -ExitCode 0).ergebnis | Should Be 'ok'
    }
    It 'SFC: Details nennen das CBS-Protokoll' {
        $z = Get-WZ 'sfc.scannow.de.teilweise'
        ($z.details -join '|').Contains('CBS.log') | Should Be $true
    }
    It 'SFC: Fortschrittszeilen stoeren die Erkennung nicht' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text "Verification 100% complete.`r`nWindows Resource Protection did not find any integrity violations." -ExitCode 0
        $z.ergebnis | Should Be 'ok'
    }
    It 'analyze englisch ja: Details' {
        $z = Get-WZ 'dism.analyze.en.empfohlen-ja'
        $z.ergebnis | Should Be 'reparierbar'
        $z.empfehlung.Contains('StartComponentCleanup') | Should Be $true
        ($z.details -contains 'Größe des Komponentenspeichers: 8,27 GB') | Should Be $true
        ($z.details -contains 'Freigebbare Pakete: 2') | Should Be $true
        ($z.details -contains 'Bereinigung empfohlen: ja') | Should Be $true
    }
    It 'analyze deutsch ja: Details' {
        $z = Get-WZ 'dism.analyze.de.empfohlen-ja'
        $z.ergebnis | Should Be 'reparierbar'
        ($z.details -contains 'Größe des Komponentenspeichers: 8,27 GB') | Should Be $true
        ($z.details -contains 'Freigebbare Pakete: 2') | Should Be $true
        ($z.details -contains 'Bereinigung empfohlen: ja') | Should Be $true
    }
    It 'analyze englisch und deutsch nein' {
        foreach ($l in 'en', 'de') {
            $z = Get-WZ ('dism.analyze.' + $l + '.empfohlen-nein')
            $z.ergebnis | Should Be 'ok'
            $z.empfehlung | Should BeNullOrEmpty
            ($z.details -contains 'Größe des Komponentenspeichers: 6,93 GB') | Should Be $true
            ($z.details -contains 'Freigebbare Pakete: 0') | Should Be $true
            ($z.details -contains 'Bereinigung empfohlen: nein') | Should Be $true
        }
    }
    It 'powercfg energy: Zaehler in den Details (de und en)' {
        foreach ($l in 'en', 'de') {
            $z = Get-WZ ('powercfg.energy.' + $l + '.ok')
            ($z.details -contains 'Fehler: 3, Warnungen: 12') | Should Be $true
            $z.text.Contains('3 Fehler, 12 Warnungen') | Should Be $true
        }
    }
    It 'details ist immer ein String-Array' {
        $z = Get-WZ 'dns.flush.en.ok'
        ($z.details -is [string[]]) | Should Be $true
        @($z.details).Count | Should Be 0
    }
    It 'winget.upgrade: nur Exit-Code' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'winget.upgrade' -Text 'egal' -ExitCode 0).ergebnis | Should Be 'ok'
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'winget.upgrade' -Text 'egal' -ExitCode 1).ergebnis | Should Be 'fehler'
    }
    It 'dns und w32tm: Fehlerausgabe' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'dns.flush' -Text 'Could not flush the DNS Resolver Cache: Function failed during execution.' -ExitCode 1).ergebnis | Should Be 'fehler'
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'zeit.resync' -Text 'The service has not been started. (0x80070426)' -ExitCode 1).ergebnis | Should Be 'problem'
    }
    It 'trim: nicht unterstuetzt ist ein Problem' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'trim' -Text 'The operation could not be completed because retrim is not supported on this volume.' -ExitCode 1).ergebnis | Should Be 'problem'
    }
}

Describe 'Get-MorpheusWartungZusammenfassung Exit-Code-Rueckfall' {
    It 'Exit 0 ohne Treffer: unbekannt' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'chkdsk.scan' -Text 'irgendwas' -ExitCode 0
        $z.ergebnis | Should Be 'unbekannt'
        $z.text | Should Be 'Beendet mit Code 0, die Ausgabe ist nicht eindeutig.'
    }
    It 'Exit ungleich 0 ohne Treffer: fehler mit Hex' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'sfc.scannow' -Text '' -ExitCode 5
        $z.ergebnis | Should Be 'fehler'
        $z.text | Should Be 'Beendet mit Fehlercode 5 (0x5).'
    }
    It 'negativer Exit-Code als uint32-Hex' {
        $z = Get-MorpheusWartungZusammenfassung -Werkzeug 'dism.cleanup' -Text 'nichts' -ExitCode (-2146498529)
        $z.ergebnis | Should Be 'fehler'
        $z.text | Should Be 'Beendet mit Fehlercode -2146498529 (0x800f081f).'
    }
    It 'ohne Exit-Code und ohne Treffer: unbekannt' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'zeit.resync' -Text 'x').ergebnis | Should Be 'unbekannt'
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'zeit.resync' -Text $null -ExitCode $null).ergebnis | Should Be 'unbekannt'
    }
    It 'Treffer in der Ausgabe schlaegt den Exit-Code' {
        (Get-MorpheusWartungZusammenfassung -Werkzeug 'dns.flush' -Text 'Successfully flushed the DNS Resolver Cache.' -ExitCode 0).ergebnis | Should Be 'ok'
    }
    It 'alle Katalog-Ids werden akzeptiert' {
        foreach ($id in 'dism.checkhealth', 'dism.scanhealth', 'dism.restorehealth', 'sfc.scannow', 'dism.analyze', 'dism.cleanup', 'chkdsk.scan', 'dns.flush', 'trim', 'zeit.resync', 'powercfg.energy', 'powercfg.akku', 'powercfg.schlaf', 'winget.upgrade') {
            $z = Get-MorpheusWartungZusammenfassung -Werkzeug $id -Text '' -ExitCode 0
            (@('ok', 'repariert', 'reparierbar', 'problem', 'fehler', 'unbekannt') -contains $z.ergebnis) | Should Be $true
        }
    }
    It 'unbekannte Id wirft' {
        { Get-MorpheusWartungZusammenfassung -Werkzeug 'format.c' -Text 'x' -ExitCode 0 } | Should Throw
        { Get-MorpheusWartungZusammenfassung -Werkzeug 'perfmon.rel' -Text 'x' -ExitCode 0 } | Should Throw
        { Get-MorpheusWartungZusammenfassung -Werkzeug 'SFC.SCANNOW' -Text 'x' -ExitCode 0 } | Should Throw
    }
}

Describe 'Get-MorpheusWartungKurzfassung' {
    It 'Beispiel mit Dauer und Exit-Code' {
        $z = [pscustomobject]@{ ergebnis = 'ok'; text = 'Keine Beschädigung gefunden.'; empfehlung = $null; details = [string[]]@() }
        Get-MorpheusWartungKurzfassung -Zusammenfassung $z -ExitCode 0 -DauerSek 72 | Should Be 'Keine Beschädigung gefunden. Dauer 1 min 12 s, Exit-Code 0.'
    }
    It 'Sekunden und Stunden' {
        $z = [pscustomobject]@{ ergebnis = 'ok'; text = 'Fertig'; empfehlung = $null; details = [string[]]@() }
        Get-MorpheusWartungKurzfassung -Zusammenfassung $z -DauerSek 45 | Should Be 'Fertig. Dauer 45 s.'
        Get-MorpheusWartungKurzfassung -Zusammenfassung $z -DauerSek 3725 -ExitCode 1 | Should Be 'Fertig. Dauer 1 h 2 min, Exit-Code 1.'
    }
    It 'haengt die ersten Details an' {
        $z = Get-WZ 'dism.analyze.de.empfohlen-ja'
        $k = Get-MorpheusWartungKurzfassung -Zusammenfassung $z -ExitCode 0 -DauerSek 30
        $k.Contains('Größe des Komponentenspeichers: 8,27 GB') | Should Be $true
        $k.Contains('Freigebbare Pakete: 2') | Should Be $true
        $k.Contains('Exit-Code 0') | Should Be $true
    }
    It 'bleibt unter 500 Zeichen' {
        $z = [pscustomobject]@{ ergebnis = 'fehler'; text = ('x' * 700); empfehlung = $null; details = [string[]]@(('y' * 300), ('z' * 300)) }
        (Get-MorpheusWartungKurzfassung -Zusammenfassung $z -ExitCode 1 -DauerSek 9).Length | Should BeLessThan 501
    }
    It 'alle Fixtures: Kurzfassung hoechstens 500 Zeichen' {
        foreach ($f in Get-ChildItem (Join-Path $script:Fix '*.txt')) {
            $n = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $k = Get-MorpheusWartungKurzfassung -Zusammenfassung (Get-WZ $n) -ExitCode 0 -DauerSek 100
            $k.Length | Should BeLessThan 501
            $k | Should Not BeNullOrEmpty
        }
    }
}
