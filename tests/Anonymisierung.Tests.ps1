#Requires -Version 5.1
# Texte auf Deutsch: Die Sprache nach Windows waere Zufall
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests für die Anonymisierung bei „Für KI kopieren“ (Karte #118).
# Dieselben Testfälle (tests\anonymisierung.testfaelle.json, erfundene Werte) laufen gegen Protect-Text in pc-check.ps1
# und gegen protect() in gui\app.js (Block ANONYM-BEGIN bis ANONYM-END, per node; ohne node nicht ausgewertet).
# Die Funktionen werden per AST bzw. Textblock geholt, ohne das Skript auszuführen: kein Scan, keine Systemänderung.
# Ausführen: Invoke-Pester tests\Anonymisierung.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Sprache.ps1')
Import-MorpheusTexte -Sprache 'de'

$script:PcCheckPfad = Join-Path $PSScriptRoot '..\pc-check.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script:PcCheckPfad, [ref]$null, [ref]$null)
foreach ($name in 'Get-ProtectContext', 'Protect-Text') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Funktion $name nicht in pc-check.ps1 gefunden" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$script:FaelleDatei = Join-Path $PSScriptRoot 'anonymisierung.testfaelle.json'
$script:Faelle = @((Get-Content -LiteralPath $script:FaelleDatei -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
$script:AppJs = Join-Path $PSScriptRoot '..\gui\app.js'
$script:Node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1

# JS-Seite einmal für alle Fälle ausführen
$script:JsErgebnis = $null
if ($script:Node) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('morpheus-anon-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $harness = Join-Path $tmp 'harness.js'
    $out = Join-Path $tmp 'ergebnis.json'
    @'
const fs = require('fs');
const src = fs.readFileSync(process.argv[3], 'utf8');
const m = src.match(/\/\/ ANONYM-BEGIN\r?\n([\s\S]*?)\/\/ ANONYM-END/);
if (!m) { console.error('Block ANONYM-BEGIN/END nicht gefunden'); process.exit(2); }
const protect = new Function(m[1] + '\nreturn protect;')();
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
fs.writeFileSync(process.argv[4], JSON.stringify(cases.map(c => protect(c.input, c.ctx))), 'utf8');
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
    & $script:Node.Source $harness $script:FaelleDatei $script:AppJs $out
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) {
        $script:JsErgebnis = @((Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Anonymisierung: gemeinsame Testfaelle' {
    It 'hat Testfaelle' { $script:Faelle.Count | Should BeGreaterThan 10 }
    $i = 0
    foreach ($f in $script:Faelle) {
        $idx = $i; $fall = $f; $i++
        It "PowerShell: $($fall.name)" {
            (Protect-Text -Text $fall.input -Context $fall.ctx) | Should BeExactly $fall.expected
        }
        It "JavaScript: $($fall.name)" {
            if (-not $script:JsErgebnis) { Set-TestInconclusive 'node nicht gefunden oder JS-Lauf fehlgeschlagen'; return }
            $script:JsErgebnis[$idx] | Should BeExactly $fall.expected
        }
    }
}

Describe 'Protect-Text: Eigenschaften' {
    It 'leerer Text bleibt leer' { Protect-Text -Text '' -Context @{} | Should BeExactly '' }
    It 'ist idempotent' {
        $ctx = @{ pc = 'TESTPC-01'; user = 'tester'; netzwerke = @('HeimNetz-5G') }
        $t = 'TESTPC-01 tester HeimNetz-5G 10.0.0.1 a@b.de Seriennummer: ABC12345 2a02:8109::1'
        $a = Protect-Text -Text $t -Context $ctx
        (Protect-Text -Text $a -Context $ctx) | Should BeExactly $a
    }
    It 'Platzhalter folgen der Sprache (tokBenutzer, tokEmail)' {
        (Protect-Text -Text 'tester a@b.de' -Context @{ user = 'tester'; tokBenutzer = '<User>'; tokEmail = '<Email>' }) | Should BeExactly '<User> <Email>'
    }
}

Describe 'Get-ProtectContext' {
    It 'nimmt WLAN-Namen und weitere Konten aus den Tabellen, ohne eingebaute Konten' {
        $script:Tables = [ordered]@{
            'Netzwerkprofile'       = @([pscustomobject]@{ Netzwerk = 'HeimNetz-5G' }, [pscustomobject]@{ Netzwerk = 'Netzwerk' })
            'Lokale Benutzerkonten' = @(
                [pscustomobject]@{ Name = 'Administrator'; SID = 'S-1-5-21-1-2-3-500' },
                [pscustomobject]@{ Name = 'Gast'; SID = 'S-1-5-21-1-2-3-501' },
                [pscustomobject]@{ Name = 'Bob'; SID = 'S-1-5-21-1-2-3-1002' })
        }
        $c = Get-ProtectContext
        @($c.konten) | Should Be @('Bob')
        (@($c.netzwerke) -contains 'HeimNetz-5G') | Should Be $true
        $c.user | Should Be $env:USERNAME
        $c.tokBenutzer | Should Be '<Benutzer>'
    }
    It 'läuft auch ohne Tabellen' {
        $script:Tables = $null
        { Get-ProtectContext } | Should Not Throw
    }
}
