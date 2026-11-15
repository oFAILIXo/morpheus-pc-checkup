#Requires -Version 5.1
# Texte auf Deutsch (2.6): Einige Tests vergleichen Meldungen; die Sprache sonst nach Windows waere Zufall
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests für pc-check.aktionen.ps1 (Aktionskatalog, T3).
# Rein lesend: Es werden nur Lesen und Voraussetzung am echten System ausgeführt, niemals Ausfuehren oder Rueckgaengig.
# Ausführen: Invoke-Pester tests\Aktionen.Tests.ps1

$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'gui\lib\Safety.ps1')

$script:CatalogFile = Join-Path $script:Root 'pc-check.aktionen.ps1'
$script:Catalog = @(Get-PcCheckCatalog -Root $script:Root)
$script:CheckText = [IO.File]::ReadAllText((Join-Path $script:Root 'pc-check.ps1'), [Text.Encoding]::UTF8)
$script:CheckNames = @([regex]::Matches($script:CheckText, "Invoke-Check '((?:[^']|'')+)'") | ForEach-Object { $_.Groups[1].Value.Replace("''", "'") })

$script:Pflicht = @('Id', 'Kategorie', 'Pruefung', 'Titel', 'Erklaerung', 'Nutzen', 'Aufwand', 'Risiko', 'Neustart', 'Bereich', 'Varianten', 'Befehle', 'Voraussetzung', 'Lesen', 'Ausfuehren', 'Rueckgaengig')
$script:Stufen = @('gering', 'mittel', 'hoch')

Describe 'Aktionskatalog: Datei' {
    It 'hat eine UTF-8-BOM (wegen der Umlaute unter Windows PowerShell 5.1)' {
        $b = [IO.File]::ReadAllBytes($script:CatalogFile)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'lässt sich ohne Syntaxfehler parsen' {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:CatalogFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should Be 0
    }
    It 'definiert keine Funktionen (Scriptblöcke müssen in sich geschlossen sein)' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:CatalogFile, [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count | Should Be 0
    }
    It 'verwendet keine script:/global:-Variablen' {
        $text = [IO.File]::ReadAllText($script:CatalogFile, [Text.Encoding]::UTF8)
        ($text -match '\$(script|global):') | Should Be $false
    }
    It 'lädt über Get-PcCheckCatalog mindestens eine Aktion' {
        $script:Catalog.Count -gt 0 | Should Be $true
    }
}

Describe 'Aktionskatalog: Aufbau' {
    It 'hat eindeutige Ids im erlaubten Format' {
        $ids = @($script:Catalog | ForEach-Object { [string]$_.Id })
        @($ids | Select-Object -Unique).Count | Should Be $ids.Count
        foreach ($i in $ids) { ($i -match '^[a-z0-9.-]+$') | Should Be $true }
    }
    It 'hat nur system.wiederherstellung mit OhneWiederherstellungspunkt' {
        $mit = @($script:Catalog | Where-Object { $_.ContainsKey('OhneWiederherstellungspunkt') })
        $mit.Count | Should Be 1
        [string]$mit[0].Id | Should Be 'system.wiederherstellung'
        $mit[0].OhneWiederherstellungspunkt | Should Be $true
    }

    foreach ($a in $script:Catalog) {
        $id = [string]$a.Id
        It "$id hat genau die erlaubten Schlüssel" {
            $erlaubt = @($script:Pflicht)
            if ($id -eq 'system.wiederherstellung') { $erlaubt += 'OhneWiederherstellungspunkt' }
            if ($a.Varianten) { $erlaubt += 'VariantenNamen' }
            foreach ($k in $script:Pflicht) { $a.ContainsKey($k) | Should Be $true }
            foreach ($k in $a.Keys) { ($erlaubt -contains $k) | Should Be $true }
        }
        It "$id hat gültige Texte, Stufen und Typen" {
            ('Sicherheit', 'Leistung', 'Gaming' -contains $a.Kategorie) | Should Be $true
            ('System', 'Benutzer' -contains $a.Bereich) | Should Be $true
            foreach ($f in 'Nutzen', 'Aufwand', 'Risiko') { ($script:Stufen -contains $a[$f]) | Should Be $true }
            ($a.Neustart -is [bool]) | Should Be $true
            foreach ($f in 'Titel', 'Erklaerung', 'Pruefung') { (([string]$a[$f]).Trim().Length -gt 0) | Should Be $true }
            if ($null -ne $a.Varianten) {
                (@($a.Varianten).Count -ge 2) | Should Be $true
                foreach ($v in @($a.Varianten)) { ($v -is [string]) | Should Be $true }
            }
            foreach ($f in 'Voraussetzung', 'Lesen', 'Ausfuehren', 'Rueckgaengig') { ($a[$f] -is [scriptblock]) | Should Be $true }
        }
        It "$id hat vollständige Befehle" {
            ($a.Befehle -is [hashtable]) | Should Be $true
            ([string]$a.Befehle.Ausfuehren).Trim().Length -gt 0 | Should Be $true
            ([string]$a.Befehle.Rueckgaengig).Trim().Length -gt 0 | Should Be $true
            (@($a.Befehle.Erklaerung).Count -gt 0) | Should Be $true
            foreach ($e in @($a.Befehle.Erklaerung)) { (([string]$e).Trim().Length -gt 0) | Should Be $true }
        }
        It "$id verweist auf eine existierende Prüfung in pc-check.ps1" {
            ($script:CheckNames -contains [string]$a.Pruefung) | Should Be $true
        }
        It "$id hat die vorgesehenen Parameter (Variante bzw. Vorher)" {
            $p1 = @($a.Ausfuehren.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $p2 = @($a.Rueckgaengig.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            ($p1 -join ',') | Should Be 'Variante'
            ($p2 -join ',') | Should Be 'Vorher'
            @($a.Lesen.Ast.ParamBlock.Parameters | Where-Object { $_ }).Count | Should Be 0
        }
        It "$id ist als HKCU-Aktion nur mit Bereich Benutzer markiert" {
            $nutztHkcu = ($a.Lesen.ToString() -match 'HKCU:')
            ($a.Bereich -eq 'Benutzer') | Should Be $nutztHkcu
        }
        It "$id wird von ConvertTo-PublicAction ohne Scriptblöcke dargestellt" {
            $pub = ConvertTo-PublicAction -Action $a
            $pub.id | Should Be $id
            ($pub.PSObject.Properties | Where-Object { $_.Value -is [scriptblock] }).Count | Should Be 0
        }
    }
}

Describe 'Aktionskatalog: Lesen und Voraussetzung am echten System (nur lesend)' {
    foreach ($a in $script:Catalog) {
        $id = [string]$a.Id
        It "$id Lesen liefert Aktiv als bool, einen Text und einen JSON-festen Zustand" {
            $s = PcCheckSafetyReadState $a
            ($s.aktiv -is [bool]) | Should Be $true
            (([string]$s.wert).Trim().Length -gt 0) | Should Be $true
            # JSON-Rundreise: Zustand bleibt gleich (Hashtable -> PSCustomObject, Zahlen evtl. Int64)
            $json = ConvertTo-Json -InputObject $s.zustand -Depth 10
            $rund = ConvertFrom-Json -InputObject $json
            (PcCheckSafetyStateKey $rund) | Should Be (PcCheckSafetyStateKey $s.zustand)
        }
        It "$id Lesen ist wiederholbar und liefert denselben Zustand" {
            $s1 = PcCheckSafetyReadState $a
            $s2 = PcCheckSafetyReadState $a
            (PcCheckSafetyStateKey $s1.zustand) | Should Be (PcCheckSafetyStateKey $s2.zustand)
            $s1.aktiv | Should Be $s2.aktiv
        }
        It "$id Voraussetzung läuft ohne Ausnahme und liefert nichts oder einen Grund" {
            $r = @(& $a.Voraussetzung)
            foreach ($x in $r) { ($x -is [string]) | Should Be $true }
        }
    }
}

# #114: Die Rücknahme nimmt Pfad/Name/Typ aus dem Katalog; aus dem Journal kommt nur der Wert.
# Die Rueckgaengig-Blöcke laufen hier mit gemockten Cmdlets (nichts am System wird geändert).
function Get-UndoBlock([string]$Id) {
    $a = @($script:Catalog | Where-Object { [string]$_.Id -ceq $Id })[0]
    [scriptblock]::Create([string]$a.Rueckgaengig)
}

Describe 'Rücknahme: gefälschter Journal-Eintrag wird abgelehnt (#114)' {
    Mock Test-Path { $true }
    Mock Get-Item { throw 'Get-Item darf nicht aufgerufen werden' }
    Mock New-Item { }
    Mock New-ItemProperty { }
    Mock Remove-ItemProperty { }
    Mock Remove-Item { }

    $einzel = @(
        @{ Id = 'fernzugriff.remoteunterstuetzung'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; Name = 'fAllowToGetHelp' },
        @{ Id = 'fernzugriff.rdp'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; Name = 'fDenyTSConnections' },
        @{ Id = 'netz.llmnr'; Pfad = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; Name = 'EnableMulticast' },
        @{ Id = 'system.schnellstart'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Name = 'HiberbootEnabled' },
        @{ Id = 'haertung.lsa'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'RunAsPPL' },
        @{ Id = 'haertung.treibersperrliste'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config'; Name = 'VulnerableDriverBlocklistEnable' },
        @{ Id = 'gaming.spielmodus'; Pfad = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled' },
        @{ Id = 'gaming.hags'; Pfad = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode' }
    )
    foreach ($z in $einzel) {
        $zid = $z.Id; $zp = $z.Pfad; $zn = $z.Name
        It "$zid verweigert einen abweichenden Typ und schreibt nichts" {
            $vorher = [pscustomobject]@{ Wert = 'C:\Evil'; Typ = 'String'; SchluesselVorhanden = $true }
            { & (Get-UndoBlock $zid) $vorher } | Should Throw 'abgelehnt'
            Assert-MockCalled New-ItemProperty -Times 0 -Scope It
            Assert-MockCalled New-Item -Times 0 -Scope It
        }
        It "$zid schreibt mit festem Pfad, Namen und Typ nur den Wert" {
            $vorher = [pscustomobject]@{ Wert = 7; Typ = 'DWord'; SchluesselVorhanden = $true }
            & (Get-UndoBlock $zid) $vorher
            Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -eq $zp -and $Name -eq $zn -and $PropertyType -eq 'DWord' -and $Value -eq 7 }
        }
    }

    It 'gaming.gamedvr lehnt einen abweichenden Pfad in irgendeinem Eintrag ab, ohne vorher etwas zu schreiben' {
        $w = {
            param($p, $n) [ordered]@{ Pfad = $p; Name = $n; Wert = 0; Typ = 'DWord'; SchluesselVorhanden = $true }
        }
        $vorher = [pscustomobject]@{ Werte = @(
                (& $w 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'),
                (& $w 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled'),
                (& $w 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'Evil')
            )
        }
        { & (Get-UndoBlock 'gaming.gamedvr') $vorher } | Should Throw 'abgelehnt'
        Assert-MockCalled New-ItemProperty -Times 0 -Scope It
        Assert-MockCalled Remove-ItemProperty -Times 0 -Scope It
    }
    It 'gaming.gamedvr lehnt abweichenden Namen, Typ und Anzahl ab' {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        $e0 = [ordered]@{ Pfad = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true }
        $e1 = [ordered]@{ Pfad = $p; Name = 'AppCaptureEnabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true }
        $e2 = [ordered]@{ Pfad = $p; Name = 'HistoricalCaptureEnabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true }
        $name = [ordered]@{ Pfad = $p; Name = 'Anderer'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true }
        $typ = [ordered]@{ Pfad = $p; Name = 'AppCaptureEnabled'; Wert = 'x'; Typ = 'String'; SchluesselVorhanden = $true }
        { & (Get-UndoBlock 'gaming.gamedvr') ([pscustomobject]@{ Werte = @($e0, $e1, $name) }) } | Should Throw 'abgelehnt'
        { & (Get-UndoBlock 'gaming.gamedvr') ([pscustomobject]@{ Werte = @($e0, $typ, $e2) }) } | Should Throw 'abgelehnt'
        { & (Get-UndoBlock 'gaming.gamedvr') ([pscustomobject]@{ Werte = @($e0) }) } | Should Throw 'abgelehnt'
        Assert-MockCalled New-ItemProperty -Times 0 -Scope It
    }
    It 'gaming.gamedvr schreibt bei passendem Eintrag nur mit Katalog-Pfaden' {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        $vorher = [pscustomobject]@{ Werte = @(
                [ordered]@{ Pfad = 'hkcu:\system\gameconfigstore'; Name = 'GameDVR_Enabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true },
                [ordered]@{ Pfad = $p; Name = 'AppCaptureEnabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true },
                [ordered]@{ Pfad = $p; Name = 'HistoricalCaptureEnabled'; Wert = 1; Typ = 'DWord'; SchluesselVorhanden = $true }
            )
        }
        & (Get-UndoBlock 'gaming.gamedvr') $vorher
        Assert-MockCalled New-ItemProperty -Times 3 -Exactly -Scope It
        Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -ceq 'HKCU:\System\GameConfigStore' -and $Name -eq 'GameDVR_Enabled' }
    }

    It 'gaming.maus lehnt abweichenden Pfad, Typ und Wert ab' {
        $p = 'HKCU:\Control Panel\Mouse'
        $mk = { param($pf, $n, $w, $t) [ordered]@{ Pfad = $pf; Name = $n; Wert = $w; Typ = $t; SchluesselVorhanden = $true } }
        $pfad = @((& $mk $p 'MouseSpeed' '1' 'String'), (& $mk $p 'MouseThreshold1' '6' 'String'), (& $mk 'HKCU:\Software\Evil' 'MouseThreshold2' '10' 'String'))
        $typ = @((& $mk $p 'MouseSpeed' '1' 'DWord'), (& $mk $p 'MouseThreshold1' '6' 'String'), (& $mk $p 'MouseThreshold2' '10' 'String'))
        $wert = @((& $mk $p 'MouseSpeed' '1' 'String'), (& $mk $p 'MouseThreshold1' 'C:\Evil.exe' 'String'), (& $mk $p 'MouseThreshold2' '10' 'String'))
        foreach ($liste in @($pfad, $typ, $wert)) {
            { & (Get-UndoBlock 'gaming.maus') ([pscustomobject]@{ Werte = $liste }) } | Should Throw 'abgelehnt'
        }
        Assert-MockCalled New-ItemProperty -Times 0 -Scope It
    }
    It 'gaming.maus schreibt Werte als String mit Katalog-Pfad' {
        $p = 'HKCU:\Control Panel\Mouse'
        $mk = { param($n, $w) [ordered]@{ Pfad = $p; Name = $n; Wert = $w; Typ = 'String'; SchluesselVorhanden = $true } }
        # Der gemockte Schlüssel liefert keine Werte: so erreicht der Test die echte Benachrichtigung an Windows nie.
        Mock Get-Item { $k = New-Object psobject; $k | Add-Member ScriptMethod GetValue { param($n) $null }; $k }
        & (Get-UndoBlock 'gaming.maus') ([pscustomobject]@{ Werte = @((& $mk 'MouseSpeed' '1'), (& $mk 'MouseThreshold1' '6'), (& $mk 'MouseThreshold2' '10')) })
        Assert-MockCalled New-ItemProperty -Times 3 -Exactly -Scope It -ParameterFilter { $LiteralPath -ceq $p -and $PropertyType -eq 'String' }
    }
    It 'gaming.maus meldet die Werte sofort an Windows, im Speicher statt per Add-Type' {
        $a = @($script:Catalog | Where-Object { [string]$_.Id -ceq 'gaming.maus' })[0]
        foreach ($b in @([string]$a.Ausfuehren, [string]$a.Rueckgaengig)) {
            $b | Should Match 'SystemParametersInfo\(4, 0,'
            $b | Should Match 'Get-PcCheckMausSpi'
            $b | Should Not Match '(?m)^[^#\r\n]*\bAdd-Type\b'
        }
        $f = [string](Get-Command Get-PcCheckMausSpi).ScriptBlock
        $f | Should Match 'DefinePInvokeMethod'
        $f | Should Not Match '(?m)^[^#\r\n]*\bAdd-Type\b'
        (Get-PcCheckMausSpi).GetMethod('SystemParametersInfo') | Should Not BeNullOrEmpty
    }
}

Describe 'Rücknahme: Defender, Laufwerke, Energieplan, Adapter (#114)' {
    It 'defender.asr-basis lehnt eine fremde Regel-Id ab und ändert nichts' {
        Mock Get-MpPreference { [pscustomobject]@{ AttackSurfaceReductionRules_Ids = @(); AttackSurfaceReductionRules_Actions = @() } }
        Mock Add-MpPreference { }
        Mock Remove-MpPreference { }
        $vorher = [pscustomobject]@{ Regeln = @(
                [ordered]@{ Id = '56a863a9-875e-4185-98a7-b882c64b5ce5'; Aktion = 1 },
                [ordered]@{ Id = 'd1e49aac-8f56-4280-b9ba-993a6d77406c'; Aktion = 0 }
            )
        }
        { & (Get-UndoBlock 'defender.asr-basis') $vorher } | Should Throw 'abgelehnt'
        Assert-MockCalled Add-MpPreference -Times 0 -Scope It
        Assert-MockCalled Remove-MpPreference -Times 0 -Scope It
    }
    It 'defender.asr-basis lehnt eine unbekannte Aktion ab' {
        Mock Get-MpPreference { [pscustomobject]@{ AttackSurfaceReductionRules_Ids = @(); AttackSurfaceReductionRules_Actions = @() } }
        Mock Add-MpPreference { }
        $vorher = [pscustomobject]@{ Regeln = @(
                [ordered]@{ Id = '56a863a9-875e-4185-98a7-b882c64b5ce5'; Aktion = 1 },
                [ordered]@{ Id = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'; Aktion = 99 }
            )
        }
        { & (Get-UndoBlock 'defender.asr-basis') $vorher } | Should Throw
        Assert-MockCalled Add-MpPreference -Times 0 -Scope It
    }
    It 'system.wiederherstellung lehnt ein fremdes Laufwerk ab' {
        Mock Disable-ComputerRestore { }
        $vorher = [pscustomobject]@{ Eingeschaltet = $false; Laufwerk = 'Z:\' }
        { & (Get-UndoBlock 'system.wiederherstellung') $vorher } | Should Throw
        Assert-MockCalled Disable-ComputerRestore -Times 0 -Scope It
    }
    It 'system.wiederherstellung-speicher lehnt Laufwerk und Grenze aus dem Journal ab' {
        { & (Get-UndoBlock 'system.wiederherstellung-speicher') ([pscustomobject]@{ Laufwerk = 'Z:'; Max = '10000MB' }) } | Should Throw
        $sys = ([IO.Path]::GetPathRoot([Environment]::SystemDirectory).TrimEnd('\'))
        { & (Get-UndoBlock 'system.wiederherstellung-speicher') ([pscustomobject]@{ Laufwerk = $sys; Max = '10GB /quiet' }) } | Should Throw
    }
    It 'energie.aspm lehnt unbekannten Plan und Werte außerhalb 0 bis 2 ab' {
        { & (Get-UndoBlock 'energie.aspm') ([pscustomobject]@{ Plan = '11111111-2222-3333-4444-555555555555'; AC = 0; DC = 0 }) } | Should Throw
        { & (Get-UndoBlock 'energie.aspm') ([pscustomobject]@{ Plan = '11111111-2222-3333-4444-555555555555'; AC = 99; DC = 0 }) } | Should Throw
    }
    It 'netz.eee lehnt fremde Schlüsselwörter, unbekannte Adapter und Werte ab, ohne etwas zu setzen' {
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'Ethernet'; Status = 'Up' } }
        Mock Get-NetAdapterAdvancedProperty { [pscustomobject]@{ RegistryValue = @('1') } }
        Mock Set-NetAdapterAdvancedProperty { }
        Mock Restart-NetAdapter { }
        $gut = [ordered]@{ Adapter = 'Ethernet'; Schluessel = '*EEE'; Wert = '0' }
        $schl = [ordered]@{ Adapter = 'Ethernet'; Schluessel = 'NetworkAddress'; Wert = '0' }
        $adap = [ordered]@{ Adapter = 'Evil'; Schluessel = '*EEE'; Wert = '0' }
        $wert = [ordered]@{ Adapter = 'Ethernet'; Schluessel = '*EEE'; Wert = '0; calc' }
        foreach ($schlecht in @($schl, $adap, $wert)) {
            { & (Get-UndoBlock 'netz.eee') ([pscustomobject]@{ Eintraege = @($gut, $schlecht) }) } | Should Throw 'abgelehnt'
        }
        Assert-MockCalled Set-NetAdapterAdvancedProperty -Times 0 -Scope It
        Assert-MockCalled Restart-NetAdapter -Times 0 -Scope It
    }
}
