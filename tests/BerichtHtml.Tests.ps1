#Requires -Version 5.1
# Texte auf Deutsch: Die Sprache nach Windows waere Zufall
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests für das Bericht-HTML (Write-HtmlReport in pc-check.ps1, Karte #121).
# Die Funktionen werden per AST aus pc-check.ps1 geholt, ohne das Skript auszuführen: kein Scan, keine Systemänderung.
# Der Bericht entsteht nur in TestDrive. Feindliche Werte (Skript-Tags, Anführungszeichen, Zeilenumbrüche, Unicode)
# laufen durch Wert, Empfehlung, Notiz, Anleitung, Befehl, Prüfname und Tabellen.
# Ausführen: Invoke-Pester tests\BerichtHtml.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Sprache.ps1')
Import-MorpheusTexte -Sprache 'de'

$script:PcCheckPfad = Join-Path $PSScriptRoot '..\pc-check.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script:PcCheckPfad, [ref]$null, [ref]$null)
foreach ($name in 'ConvertTo-HtmlText', 'Get-ProtectContext', 'Protect-Text', 'Write-HtmlReport', 'Get-ProfilName', 'Get-PruefName', 'Get-StufeName') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Funktion $name nicht in pc-check.ps1 gefunden" }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:OriginalT = ${function:T}

# Zustand, den Write-HtmlReport aus dem Skript erbt
$ProductName = 'Morpheus'; $ProductTagline = 'PC Check-up'; $ScriptVersion = '0.0.0-test'; $Sprache = 'de'; $EventDays = 14
$duration = [TimeSpan]::FromSeconds(5)
$updateResults = $null
$changes = $null
$history = New-Object System.Collections.Generic.List[object]
$rank = @{ CRIT = 0; WARN = 1; TIPP = 2; INFO = 3; ACK = 4; SKIP = 5; OK = 6 }
$script:IsAdmin = $false; $script:Profile = 'Office'; $script:ProfileAuto = $false
$script:Help = $null
$script:OS = [pscustomobject]@{ Caption = 'Test-OS' }
$script:CV = [pscustomobject]@{ DisplayVersion = 'X' }
$script:ChangesSpalten = @{}; $script:UpdateSpalten = @{}
$script:StatusNamen = @{}
foreach ($s in 'CRIT', 'WARN', 'TIPP', 'ACK', 'INFO', 'OK', 'SKIP') { $script:StatusNamen[$s] = T "bericht.status.$s" }

# Feindliche Werte
$script:Boese = @(
    '<script>alert(1)</script>',
    'a"b''c" onmouseover="alert(1)',
    '</script><script>alert(2)</script>',
    '&amp; &lt;b&gt; &#60;',
    '<img src=x onerror=alert(3)>',
    "Zeile1`r`nZeile2`n<b>x</b>",
    "Unicode: $([char]0x2028)$([char]0x2029) $([char]0x00A0) </SCRIPT >"
)

function New-FeindlichBericht {
    $script:Findings = New-Object System.Collections.Generic.List[object]
    $script:Tables = [ordered]@{}
    $script:Tables['<script>tabelle</script>'] = @([pscustomobject]@{ 'Sp"alte<x>' = '<script>alert(9)</script>'; Zwei = '"><img onerror=alert(8)>' })
    $i = 0
    foreach ($b in $script:Boese) {
        foreach ($st in 'CRIT', 'WARN', 'TIPP', 'INFO', 'OK', 'ACK') {
            $i++
            $nameOhneUmbruch = ($b -replace '[\r\n]', ' ')
            $script:Findings.Add([pscustomobject][ordered]@{
                    Area = 'Sicherheit'; Category = "Kat$($i % 3)"; Check = "Check$i $nameOhneUmbruch"; Status = $st
                    Value = $b; ValueDe = $b; Recommendation = "$b ms-settings:privacy"; OriginalStatus = 'WARN'; Note = $b
                    Effort = 'gering'; Benefit = 'hoch'; Risk = 'mittel'; Steps = @($b, "2. $b"); Command = $b
                    AreaName = $b; CategoryName = $b; CheckName = "Name $nameOhneUmbruch"
                })
        }
    }
    $pfad = Join-Path $TestDrive 'bericht.html'
    Write-HtmlReport -Path $pfad
    [IO.File]::ReadAllText($pfad, [Text.Encoding]::UTF8)
}

# Inhalt aller <script>-Blöcke
function Get-Skripte([string]$Html) { @([regex]::Matches($Html, '(?is)<script>(.*?)</script>') | ForEach-Object { $_.Groups[1].Value }) }

Describe 'Bericht-HTML mit feindlichen Werten' {
    $html = New-FeindlichBericht
    $skripte = @(Get-Skripte $html)
    $ohneSkript = [regex]::Replace($html, '(?is)<script>.*?</script>', '')

    It 'erzeugt genau einen eigenen Skriptblock' {
        $skripte.Count | Should Be 1
        ([regex]::Matches($html, '(?i)<script')).Count | Should Be 1
    }
    It 'enthält kein Skript-Tag aus Daten im HTML-Text' {
        $ohneSkript | Should Not Match '(?i)<script'
        $ohneSkript | Should Not Match '(?i)</script'
    }
    It 'enthält kein rohes img- oder b-Tag aus Daten' {
        $ohneSkript | Should Not Match '<img'
        $ohneSkript | Should Not Match '<b>x</b>'
    }
    It 'kodiert die Daten als Entitäten (inklusive &amp; als &amp;amp;)' {
        $ohneSkript | Should Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $ohneSkript | Should Match '&amp;amp; &amp;lt;b&amp;gt; &amp;#60;'
    }
    It 'kodiert Anführungszeichen in Attributen: kein ausbrechendes "' {
        $attr = [regex]::Matches($ohneSkript, '(?s)data-(?:check|name|text)="([^"]*)"')
        $attr.Count | Should BeGreaterThan 10
        $ohneSkript | Should Not Match 'onmouseover="alert'
        $ohneSkript | Should Match 'data-check="Check\d+ a&quot;b(&#39;|&#x27;|'')c&quot; onmouseover=&quot;alert\(1\)"'
    }
    It 'läßt keine Ereignis-Attribute aus Daten als Attribut entstehen' {
        # Tags mit Beachtung der Anführungszeichen; Attributwerte entfernen, dann darf kein on...=-Attribut übrig sein
        $tags = [regex]::Matches($ohneSkript, '<[a-zA-Z](?:[^>"'']|"[^"]*"|''[^'']*'')*>') | ForEach-Object { $_.Value -replace '"[^"]*"', '""' }
        @($tags).Count | Should BeGreaterThan 50
        @($tags | Where-Object { $_ -match '\son(error|mouseover|click|load)\s*=' }).Count | Should Be 0
    }
    It 'schreibt in Tabellen (Kopf und Zelle) nur kodierte Werte' {
        $ohneSkript | Should Match '&lt;script&gt;tabelle&lt;/script&gt;'
        $ohneSkript | Should Match '<td>&lt;script&gt;alert\(9\)&lt;/script&gt;</td>'
        $ohneSkript | Should Match '<td>&quot;&gt;&lt;img onerror=alert\(8\)&gt;</td>'
    }
    It 'kodiert die KI-Kopiervorlage im Textfeld (kein </textarea>-Ausbruch)' {
        $ki = [regex]::Match($ohneSkript, '(?s)<textarea id="ki-text"[^>]*>(.*?)</textarea>').Groups[1].Value
        $ki | Should Not BeNullOrEmpty
        $ki | Should Not Match '<'
    }
    It 'rahmt die Befunde der KI-Kopiervorlage mit zufälliger Markierung ein' {
        $ki = [Net.WebUtility]::HtmlDecode([regex]::Match($ohneSkript, '(?s)<textarea id="ki-text"[^>]*>(.*?)</textarea>').Groups[1].Value)
        $m = [regex]::Match($ki, '(?s)\[MORPHEUS-\w+ ([0-9A-F]{8}) \w+\]\r?\n(.*)\r?\n\[MORPHEUS-\w+ \1 \w+\]')
        $m.Success | Should Be $true
        $m.Groups[2].Value | Should Match '== '
        $ki.IndexOf($m.Groups[1].Value) | Should BeLessThan $ki.IndexOf('[MORPHEUS-')
    }
    It 'endet wohlgeformt mit dem einen Skriptblock' {
        $html.TrimEnd() | Should Match '</script></body></html>$'
    }
}

Describe 'Eingebettetes Skript und JSON' {
    It 'enthält im Skript kein </script und kein <script, auch wenn ein Sprachtext es versucht' {
        # Nur im Speicher: T liefert für die JS-Texte feindliche Werte
        function T {
            param([string]$Key)
            if ($Key -like 'bericht.js.*') { return "</script><script>alert(5)</script> `"x`" \ $Key" }
            & $script:OriginalT $Key @args
        }
        $html = New-FeindlichBericht
        $skripte = @(Get-Skripte $html)
        $skripte.Count | Should Be 1
        $skripte[0] | Should Not Match '(?i)</script'
        $skripte[0] | Should Not Match '(?i)<script'
        $skripte[0] | Should Not Match '__MORPHEUS_TEXTE__'
        $skripte[0] | Should Match '\\u003c/script\\u003e\\u003cscript\\u003ealert\(5\)'
    }
    It 'normaler Bericht: Platzhalter ersetzt, kein </script im Skript' {
        $skript = @(Get-Skripte (New-FeindlichBericht))[0]
        $skript | Should Not Match '(?i)</script'
        $skript | Should Not Match '__MORPHEUS_TEXTE__'
        $skript | Should Match 'kiKopiert'
    }
}

Describe 'Maskierung der JSON-Texte' {
    It 'pc-check.ps1 ersetzt < im JSON durch \u003c' {
        $zeile = Get-Content -LiteralPath $script:PcCheckPfad -Encoding UTF8 | Where-Object { $_ -match 'ConvertTo-Json -Compress\)\.Replace\(' } | Select-Object -First 1
        $zeile | Should Not BeNullOrEmpty
        $zeile | Should Match ([regex]::Escape("Replace('<', '\u003c')"))
    }
    It 'das Muster macht aus </script> in JSON ein gültiges, tagfreies Literal' {
        $json = ([ordered]@{ a = '</script><script>x"y' } | ConvertTo-Json -Compress).Replace('<', '\u003c')
        $json | Should Not Match '<'
        $json | Should Match '^\{"a":"\\u003c/script'
        ($json | ConvertFrom-Json).a | Should Be '</script><script>x"y'
    }
}
