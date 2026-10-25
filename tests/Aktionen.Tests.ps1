#Requires -Version 5.1
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
