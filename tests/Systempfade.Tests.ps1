#Requires -Version 5.1
# Pester-3.4-Tests fuer gui\lib\Systempfade.ps1 und die statische Pruefung des Admin-Codes (Hotfix 2.3.3).
# Teil A: AST-Pruefung (Modulpfad-Haertung, volle Programmpfade, -NoProfile, keine Umgebungsvariablen fuer Systemordner).
# Teil B: Funktionen aus Systempfade.ps1 mit Attrappen (keine Registry, kein Download, keine Installation).
# Teil C: Ein Kindprozess (powershell.exe -NoProfile) bekommt die Haertung; es wird nur gelesen.
# Ausfuehren: Invoke-Pester tests\Systempfade.Tests.ps1

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:SpFile = Join-Path $script:Root 'gui\lib\Systempfade.ps1'
$script:PsModPathVorher = $env:PSModulePath
. $script:SpFile
$script:PsModPathNachher = $env:PSModulePath

# ---------------------------------------------------------------- Hilfsfunktionen Teil A

$script:AdminRel = @('pc-check.ps1', 'pc-check.aktionen.ps1', 'pc-check-gui.ps1', 'pc-check-start.ps1') +
    @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'gui\lib') -Filter *.ps1 | Sort-Object Name | ForEach-Object { 'gui\lib\' + $_.Name })
$script:Model = $null
$script:CmdCache = @{}

function Get-AdminModel {
    if ($script:Model) { return $script:Model }
    $m = New-Object System.Collections.ArrayList
    foreach ($rel in $script:AdminRel) {
        $path = Join-Path $script:Root $rel
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$err)
        $lines = [IO.File]::ReadAllLines($path)
        # Zeilen, die nur aus Kommentar bestehen (Zeilenkommentar oder innerhalb eines Blockkommentars)
        $kom = @{}
        foreach ($t in $tok) {
            if ($t.Kind -ne 'Comment') { continue }
            for ($n = $t.Extent.StartLineNumber; $n -le $t.Extent.EndLineNumber; $n++) {
                if ($n -gt $t.Extent.StartLineNumber) { $kom[$n] = $true; continue }
                $vor = $lines[$n - 1].Substring(0, [Math]::Min($t.Extent.StartColumnNumber - 1, $lines[$n - 1].Length))
                if ($vor.Trim() -eq '') { $kom[$n] = $true }
            }
        }
        [void]$m.Add([pscustomobject]@{ Rel = $rel; Path = $path; Ast = $ast; Errors = $err; Lines = $lines; Kommentar = $kom })
    }
    $script:Model = $m
    $m
}

function Get-CodeZeilen($f) {
    for ($i = 1; $i -le $f.Lines.Count; $i++) {
        if (-not $f.Kommentar.ContainsKey($i)) { [pscustomobject]@{ Nr = $i; Text = $f.Lines[$i - 1] } }
    }
}

function Test-HaertungStatement($st) {
    if ($null -eq $st) { return 'keine Anweisung vorhanden' }
    if ($st -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return 'erste Anweisung ist keine Zuweisung: ' + $st.Extent.Text }
    if ($st.Left.Extent.Text -ne '$env:PSModulePath') { return 'Zuweisung nicht an $env:PSModulePath: ' + $st.Left.Extent.Text }
    $r = $st.Right.Extent.Text
    if ($r -notmatch [regex]::Escape('[Environment]::SystemDirectory')) { return 'rechte Seite ohne SystemDirectory' }
    if ($r -notmatch [regex]::Escape("GetFolderPath('ProgramFiles')")) { return 'rechte Seite ohne GetFolderPath(ProgramFiles)' }
    if ($r -match [regex]::Escape('$env:')) { return 'rechte Seite verwendet $env:' }
    $null
}

function Get-ErsteAnweisung($scriptBlockAst) {
    if (($null -eq $scriptBlockAst.EndBlock) -or ($scriptBlockAst.EndBlock.Statements.Count -lt 1)) { return $null }
    $scriptBlockAst.EndBlock.Statements[0]
}

function Test-Absolut([string]$s) { $s -match '^([A-Za-z]:\\|\\\\)' }

# Argument, das als Programm dient: -FilePath/-File/-Exe oder erstes Positionsargument
function Get-ProgrammArgument($c) {
    $els = $c.CommandElements
    for ($i = 1; $i -lt $els.Count; $i++) {
        $e = $els[$i]
        if (($e -is [System.Management.Automation.Language.CommandParameterAst]) -and ($e.ParameterName -match '^(FilePath|File|Exe)$')) {
            if ($e.Argument) { return $e.Argument }
            if ($i + 1 -lt $els.Count) { return $els[$i + 1] }
            return $null
        }
    }
    for ($i = 1; $i -lt $els.Count; $i++) {
        $e = $els[$i]
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if (($i -gt 1) -and ($els[$i - 1] -is [System.Management.Automation.Language.CommandParameterAst]) -and (-not $els[$i - 1].Argument)) { continue }
        return $e
    }
    $null
}

function Get-StartJobBloecke($ast) {
    $cmds = $ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Start-Job') }, $true)
    foreach ($c in $cmds) {
        $els = $c.CommandElements
        for ($i = 1; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if (($e -is [System.Management.Automation.Language.CommandParameterAst]) -and ($e.ParameterName -eq 'ScriptBlock') -and ($i + 1 -lt $els.Count)) {
                if ($els[$i + 1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $els[$i + 1] }
                break
            }
        }
    }
}

function Get-GuiJobScripts {
    $f = Get-AdminModel | Where-Object { $_.Rel -eq 'gui\lib\Server.ps1' }
    $a = $f.Ast.Find({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$script:GuiJobScripts') }, $true)
    if (-not $a) { return @() }
    $h = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    foreach ($kv in $h.KeyValuePairs) {
        [pscustomobject]@{
            Key   = $kv.Item1.Extent.Text.Trim("'", '"')
            Block = $kv.Item2.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        }
    }
}

# ---------------------------------------------------------------- Teil A

Describe 'Admin-Code: statische Pruefung (Teil A)' {

    It 'alle Admin-Dateien lassen sich ohne Fehler parsen' {
        $fehler = @()
        foreach ($f in Get-AdminModel) { foreach ($e in @($f.Errors)) { $fehler += ('{0}:{1} {2}' -f $f.Rel, $e.Extent.StartLineNumber, $e.Message) } }
        ($fehler -join "`n") | Should Be ''
        @(Get-AdminModel).Count | Should BeGreaterThan 8
    }

    It 'Einstiegspunkte: erste Anweisung ist die Haertung von PSModulePath' {
        $funde = @()
        foreach ($rel in 'pc-check.ps1', 'pc-check-gui.ps1', 'pc-check-start.ps1') {
            $f = Get-AdminModel | Where-Object { $_.Rel -eq $rel }
            $grund = Test-HaertungStatement (Get-ErsteAnweisung $f.Ast)
            if ($grund) { $funde += ('{0}: {1}' -f $rel, $grund) }
        }
        ($funde -join "`n") | Should Be ''
    }

    It 'Start-Job-Scriptbloecke (literal) beginnen mit der Haertung' {
        $funde = @(); $anzahl = 0; $anzahlPcCheck = 0
        foreach ($f in Get-AdminModel) {
            foreach ($b in @(Get-StartJobBloecke $f.Ast)) {
                $anzahl++
                if ($f.Rel -eq 'pc-check.ps1') { $anzahlPcCheck++ }
                $grund = Test-HaertungStatement (Get-ErsteAnweisung $b.ScriptBlock)
                if ($grund) { $funde += ('{0}:{1} {2}' -f $f.Rel, $b.Extent.StartLineNumber, $grund) }
            }
        }
        ($funde -join "`n") | Should Be ''
        $anzahlPcCheck | Should BeGreaterThan 0
    }

    It 'GuiJobScripts: genau 9 Eintraege (2.4: wartung, updatesuche), jeder beginnt mit der Haertung' {
        $eintraege = @(Get-GuiJobScripts)
        $eintraege.Count | Should Be 9
        (($eintraege | ForEach-Object { $_.Key } | Sort-Object) -join ',') | Should Be 'defender,refresh,run,scan,speicher,sysinternals,undo,updatesuche,wartung'
        $funde = @()
        foreach ($e in $eintraege) {
            if (-not $e.Block) { $funde += ('{0}: kein Scriptblock' -f $e.Key); continue }
            $grund = Test-HaertungStatement (Get-ErsteAnweisung $e.Block.ScriptBlock)
            if ($grund) { $funde += ('GuiJobScripts.{0}: {1}' -f $e.Key, $grund) }
        }
        ($funde -join "`n") | Should Be ''
    }

    It 'keine Programme ohne vollen Pfad (Befehle, Programmargumente, FileName, Get-Command)' {
        $funde = New-Object System.Collections.Generic.List[string]
        $model = Get-AdminModel
        $eigene = @{}
        foreach ($f in $model) {
            foreach ($d in $f.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $eigene[$d.Name.ToLowerInvariant()] = $true }
        }
        $progAufrufe = @('invoke-native', 'start-process', 'pccheckSicherungnative'.ToLowerInvariant(), 'morpheussysstart')
        foreach ($f in $model) {
            $cmds = $f.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $cmds) {
                $zeile = $c.Extent.Text.Split("`n")[0].Trim()
                $ort = '{0}:{1} {2}' -f $f.Rel, $c.Extent.StartLineNumber, $zeile
                $name = $c.GetCommandName()
                if ($null -ne $name) {
                    $ln = $name.ToLowerInvariant()
                    if ($name -match '\.(exe|com|cmd|bat)$') {
                        if (-not (Test-Absolut $name)) { $funde.Add($ort + ' [Programm ohne vollen Pfad]') }
                    }
                    elseif (-not $eigene.ContainsKey($ln)) {
                        if (-not $script:CmdCache.ContainsKey($ln)) {
                            $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
                            $script:CmdCache[$ln] = [string]$(if ($cmd) { $cmd.CommandType } else { '' })
                        }
                        if ($script:CmdCache[$ln] -eq 'Application') { $funde.Add($ort + ' [externes Programm ohne Pfad]') }
                    }
                    if ($progAufrufe -contains $ln) {
                        $arg = Get-ProgrammArgument $c
                        if (($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and (-not (Test-Absolut $arg.Value))) {
                            $funde.Add($ort + ' [Programmargument ohne absoluten Pfad]')
                        }
                    }
                    if ($ln -eq 'get-command') {
                        $arg = $null
                        $els = $c.CommandElements
                        for ($i = 1; $i -lt $els.Count; $i++) {
                            if (($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]) -and ($els[$i].ParameterName -eq 'Name') -and ($i + 1 -lt $els.Count)) { $arg = $els[$i + 1]; break }
                        }
                        if (-not $arg) { $arg = Get-ProgrammArgument $c }
                        if (($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ($arg.Value -match '\.exe$')) {
                            $funde.Add($ort + ' [Get-Command mit .exe-Literal]')
                        }
                    }
                }
            }
            $zuw = $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -match '\.FileName$') }, $true)
            foreach ($z in $zuw) {
                if (($z.Right -is [System.Management.Automation.Language.CommandExpressionAst]) -and ($z.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
                    if (-not (Test-Absolut $z.Right.Expression.Value)) {
                        $funde.Add(('{0}:{1} {2} [FileName ohne absoluten Pfad]' -f $f.Rel, $z.Extent.StartLineNumber, $z.Extent.Text.Split("`n")[0].Trim()))
                    }
                }
            }
        }
        ($funde -join "`n") | Should Be ''
    }

    It 'kein Get-Command winget und kein Get-Command nvidia-smi mehr' {
        $funde = @()
        foreach ($f in Get-AdminModel) {
            foreach ($z in Get-CodeZeilen $f) {
                if ($z.Text -match 'Get-Command\s+(-Name\s+)?[''"]?(winget|nvidia-smi)\b') { $funde += ('{0}:{1} {2}' -f $f.Rel, $z.Nr, $z.Text.Trim()) }
            }
        }
        ($funde -join "`n") | Should Be ''
    }

    It 'powershell.exe wird nur mit -NoProfile gestartet' {
        $funde = @()
        foreach ($f in Get-AdminModel) {
            $code = @(Get-CodeZeilen $f)
            $gesamt = ($code | ForEach-Object { $_.Text }) -join "`n"
            foreach ($z in $code) {
                if ($z.Text -match '-ExecutionPolicy' -and $z.Text -match '-File' -and $z.Text -notmatch '-NoProfile') {
                    $funde += ('{0}:{1} ohne -NoProfile: {2}' -f $f.Rel, $z.Nr, $z.Text.Trim())
                }
                if (($z.Text -match 'powershell\.exe') -and ($z.Text -notmatch '-in\s+''powershell\.exe''') -and ($gesamt -notmatch '-NoProfile')) {
                    $funde += ('{0}:{1} startet powershell.exe, Datei enthaelt kein -NoProfile: {2}' -f $f.Rel, $z.Nr, $z.Text.Trim())
                }
            }
            # Start-Process / & mit powershell-Programm: zugehoerige Argumentzeile muss -NoProfile enthalten
            foreach ($c in $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Start-Process') }, $true)) {
                if ($c.Extent.Text -match '\$psExe|powershell\.exe') {
                    $arg = $c.CommandElements | Where-Object { $_.Extent.Text -match '^\$(argLine|al)\b' } | Select-Object -First 1
                    if ($arg) {
                        $var = $arg.Extent.Text.TrimStart('$')
                        $zuw = $f.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Where-Object { ($_.Left.Extent.Text -eq ('$' + $var)) -and ($_.Extent.StartLineNumber -le $c.Extent.StartLineNumber) } | Where-Object { $_.Operator -eq 'Equals' } | Select-Object -Last 1
                        if ((-not $zuw) -or ($zuw.Extent.Text -notmatch '-NoProfile')) { $funde += ('{0}:{1} Argumente ({2}) ohne -NoProfile' -f $f.Rel, $c.Extent.StartLineNumber, $var) }
                    }
                    elseif ($c.Extent.Text -notmatch '-NoProfile') { $funde += ('{0}:{1} Start-Process ohne -NoProfile' -f $f.Rel, $c.Extent.StartLineNumber) }
                }
            }
        }
        ($funde -join "`n") | Should Be ''
    }

    It '.cmd-Starter: voller Pfad mit -NoProfile, ASCII, CRLF' {
        foreach ($n in 'pc-check.cmd', 'pc-check-gui.cmd') {
            $p = Join-Path $script:Root $n
            $bytes = [IO.File]::ReadAllBytes($p)
            @($bytes | Where-Object { $_ -ge 128 }).Count | Should Be 0
            $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
            $crlf = 0
            for ($i = 1; $i -lt $bytes.Length; $i++) { if (($bytes[$i] -eq 10) -and ($bytes[$i - 1] -eq 13)) { $crlf++ } }
            $lf | Should BeGreaterThan 0
            $crlf | Should Be $lf
            $zeilen = [IO.File]::ReadAllLines($p)
            @($zeilen | Where-Object { $_ -match '^\s*powershell(\.exe)?\b' }).Count | Should Be 0
            @($zeilen | Where-Object { $_ -match '^"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile\b' }).Count | Should Be 1
        }
    }

    It 'pc-check-gui.ps1 startet keinen Standardbrowser (kein Start-Process $url)' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check-gui.ps1' }
        $funde = @()
        foreach ($c in $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Start-Process') }, $true)) {
            $arg = Get-ProgrammArgument $c
            if ($arg -and ($arg.Extent.Text -match '^\$url\b')) { $funde += ('{0}:{1} {2}' -f $f.Rel, $c.Extent.StartLineNumber, $c.Extent.Text) }
        }
        ($funde -join "`n") | Should Be ''
    }

    It 'keine Systemordner ueber Umgebungsvariablen (ProgramFiles, ProgramData, SystemRoot)' {
        $funde = @()
        foreach ($rel in 'pc-check-gui.ps1', 'pc-check-start.ps1', 'gui\lib\Install.ps1') {
            $f = Get-AdminModel | Where-Object { $_.Rel -eq $rel }
            foreach ($z in Get-CodeZeilen $f) {
                if ($z.Text -match '(?i)env:(ProgramFiles|ProgramData|SystemRoot)') { $funde += ('{0}:{1} {2}' -f $rel, $z.Nr, $z.Text.Trim()) }
            }
        }
        ($funde -join "`n") | Should Be ''
    }
}

# ---------------------------------------------------------------- Teil B

Describe 'Systempfade.ps1: Dot-Source' {
    It 'fuehrt beim Laden nichts aus (PSModulePath unveraendert)' {
        $script:PsModPathNachher | Should Be $script:PsModPathVorher
    }
}

Describe 'Get-MorpheusModulPfad' {
    It 'liefert genau zwei gesicherte Eintraege, keinen im Benutzerprofil' {
        $teile = @((Get-MorpheusModulPfad) -split ';')
        $teile.Count | Should Be 2
        $teile[0] | Should Be ([Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules')
        $teile[1] | Should Be ([Environment]::GetFolderPath('ProgramFiles') + '\WindowsPowerShell\Modules')
        $profil = [Environment]::GetFolderPath('UserProfile')
        foreach ($t in $teile) { $t.StartsWith($profil, [StringComparison]::OrdinalIgnoreCase) | Should Be $false }
    }
}

Describe 'Get-MorpheusSystemProgramm' {
    It 'whoami.exe liegt in System32 und existiert' {
        $p = Get-MorpheusSystemProgramm 'whoami.exe'
        $p.StartsWith([Environment]::SystemDirectory, [StringComparison]::OrdinalIgnoreCase) | Should Be $true
        [IO.File]::Exists($p) | Should Be $true
    }
    It 'Unterordner wie WindowsPowerShell\v1.0\powershell.exe sind erlaubt' {
        $p = Get-MorpheusSystemProgramm 'WindowsPowerShell\v1.0\powershell.exe'
        [IO.File]::Exists($p) | Should Be $true
        $p | Should Be (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe')
    }
    foreach ($bad in '..\x.exe', 'C:\x.exe', 'x.ps1', 'a/b.exe', 'gibtsnicht-xyz.exe') {
        It ('lehnt ab: ' + $bad) {
            { Get-MorpheusSystemProgramm $bad } | Should Throw
        }
    }
}

Describe 'Test-MorpheusMicrosoftSignatur' {
    $gut = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
    $w2011 = '8F43288AD272F3103B6FB1428485EA3014C0BCFE'

    BeforeEach {
        $script:Orig = @{} + $script:MorpheusPfadImpl
        $script:FStatus = 'Valid'
        $script:FSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        $script:FWurzel = '8F43288AD272F3103B6FB1428485EA3014C0BCFE'
        $script:FWurzelWirft = $false
        $script:MorpheusPfadImpl.Signatur = { param($Pfad) [pscustomobject]@{ Status = $script:FStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:FSubject } } }
        $script:MorpheusPfadImpl.Wurzel = { param($Zertifikat) if ($script:FWurzelWirft) { throw 'Kette kaputt' }; $script:FWurzel }
    }
    AfterEach { foreach ($k in $script:Orig.Keys) { $script:MorpheusPfadImpl[$k] = $script:Orig[$k] } }

    It 'Valid + Microsoft + Wurzel 2011 -> $null' {
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should BeNullOrEmpty
    }
    It 'Valid + Microsoft + Wurzel 2010 -> $null' {
        $script:FWurzel = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should BeNullOrEmpty
    }
    It 'Status NotSigned -> Grund' {
        $script:FStatus = 'NotSigned'
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should Match 'NotSigned'
    }
    It 'fremder Herausgeber -> Grund' {
        $script:FSubject = 'CN=Evil, O=Evil Corp'
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should Match 'Microsoft'
    }
    foreach ($s in 'CN=x, O=Microsoft Corporationx', 'CN=x, O=Microsoft Corporation Fake', 'OU=O=Microsoft Corporation', 'CN=Microsoft Corporation, OU=Microsoft Corporation') {
        It ('abgelehnt: ' + $s) {
            $script:FSubject = $s
            [string](Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe') | Should Not BeNullOrEmpty
        }
    }
    It 'falsche Wurzel -> Grund' {
        $script:FWurzel = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should Match 'Wurzel'
    }
    It 'Wurzel wirft -> Grund' {
        $script:FWurzelWirft = $true
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should Match 'Wurzel'
    }
    It 'Signatur wirft -> Grund' {
        $script:MorpheusPfadImpl.Signatur = { param($Pfad) throw 'kaputt' }
        Test-MorpheusMicrosoftSignatur -Pfad 'C:\x\winget.exe' | Should Match 'kaputt'
    }
}

Describe 'Get-MorpheusWinget' {
    $pub = '8wekyb3d8bbwe'

    BeforeEach {
        $script:Orig = @{} + $script:MorpheusPfadImpl
        $script:FPakete = @()
        $script:FPaketeWirft = $null
        $script:FAttr = [IO.FileAttributes]::Archive
        $script:FUngueltigMuster = $null
        $script:FDateiFehlt = $false
        $script:FPgmAufrufe = New-Object System.Collections.ArrayList
        $script:MorpheusPfadImpl.ProgrammeOrdner = { 'C:\PF' }
        $script:MorpheusPfadImpl.Pakete = { if ($script:FPaketeWirft) { throw $script:FPaketeWirft }; $script:FPakete }
        $script:MorpheusPfadImpl.Datei = { param($Pfad) [void]$script:FPgmAufrufe.Add($Pfad); if ($script:FDateiFehlt) { throw 'fehlt' }; [pscustomobject]@{ Attributes = $script:FAttr } }
        $script:MorpheusPfadImpl.Signatur = {
            param($Pfad)
            $st = 'Valid'
            if ($script:FUngueltigMuster -and ($Pfad -like $script:FUngueltigMuster)) { $st = 'HashMismatch' }
            [pscustomobject]@{ Status = $st; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }
        }
        $script:MorpheusPfadImpl.Wurzel = { param($Zertifikat) '8F43288AD272F3103B6FB1428485EA3014C0BCFE' }
    }
    AfterEach { foreach ($k in $script:Orig.Keys) { $script:MorpheusPfadImpl[$k] = $script:Orig[$k] } }

    function New-Paket([string]$Version, [string]$Ort, [string]$Publisher = '8wekyb3d8bbwe') {
        [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; PackageFullName = 'Microsoft.DesktopAppInstaller_' + $Version; Version = $Version; PublisherId = $Publisher; InstallLocation = $Ort }
    }
    function Get-GutOrt([string]$Version) { 'C:\PF\WindowsApps\Microsoft.DesktopAppInstaller_' + $Version + '_x64__8wekyb3d8bbwe' }

    It 'gutes Paket -> voller Pfad zu winget.exe' {
        $script:FPakete = @(New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0'))
        $r = Get-MorpheusWinget
        $r.Pfad | Should Be ((Get-GutOrt '1.2.3.0') + '\winget.exe')
        $r.Grund | Should BeNullOrEmpty
        $r.Version | Should Be '1.2.3.0'
    }
    It 'InstallLocation im Benutzerprofil -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.2.3.0' 'C:\Users\x\AppData\Local\Microsoft\WindowsApps')
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'InstallLocation mit .. -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.0.0.0' 'C:\PF\WindowsApps\Microsoft.DesktopAppInstaller_1\..\..\evil')
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'Unterordner im Paketordner -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.0.0.0' 'C:\PF\WindowsApps\Microsoft.DesktopAppInstaller_x\sub')
        (Get-MorpheusWinget).Pfad | Should BeNullOrEmpty
    }
    It 'falsche PublisherId -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0') 'abcdefghijklm')
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'winget.exe als ReparsePoint -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0'))
        $script:FAttr = [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::ReparsePoint
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'ungueltige Signatur -> abgelehnt' {
        $script:FPakete = @(New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0'))
        $script:FUngueltigMuster = '*'
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'zwei gueltige Pakete: Version wird numerisch verglichen (1.10.0.0 gewinnt)' {
        $script:FPakete = @((New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0')), (New-Paket '1.10.0.0' (Get-GutOrt '1.10.0.0')))
        $r = Get-MorpheusWinget
        $r.Pfad | Should Be ((Get-GutOrt '1.10.0.0') + '\winget.exe')
        $r.Version | Should Be '1.10.0.0'
    }
    It 'hoechste Version ungueltig -> zweites Paket wird genommen' {
        $script:FPakete = @((New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0')), (New-Paket '1.10.0.0' (Get-GutOrt '1.10.0.0')))
        $script:FUngueltigMuster = '*1.10.0.0*'
        $r = Get-MorpheusWinget
        $r.Pfad | Should Be ((Get-GutOrt '1.2.3.0') + '\winget.exe')
    }
    It 'Pakete wirft -> Pfad leer, Grund enthaelt die Meldung' {
        $script:FPaketeWirft = 'Appx kaputt'
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Match 'Appx kaputt'
    }
    It 'keine Pakete -> Pfad leer, Grund gesetzt' {
        $script:FPakete = @()
        $r = Get-MorpheusWinget
        $r.Pfad | Should BeNullOrEmpty
        $r.Grund | Should Not BeNullOrEmpty
    }
    It 'kein Rueckgriff auf PATH: bei Fehlschlag bleibt der Pfad leer' {
        $script:FPakete = @(New-Paket '1.2.3.0' (Get-GutOrt '1.2.3.0'))
        $script:FDateiFehlt = $true
        (Get-MorpheusWinget).Pfad | Should BeNullOrEmpty
        $script:FPakete = @()
        (Get-MorpheusWinget).Pfad | Should BeNullOrEmpty
    }
}

Describe 'Set-MorpheusTempPfad' {
    BeforeEach {
        $script:TempVorher = $env:TEMP
        $script:TmpVorher = $env:TMP
        $script:SpRoot = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusSpTest_' + [guid]::NewGuid().ToString('N'))
        Remove-Item -LiteralPath function:\Test-MorpheusSecurePath -ErrorAction SilentlyContinue
        $script:FSicher = $false
    }
    AfterEach {
        $env:TEMP = $script:TempVorher
        $env:TMP = $script:TmpVorher
        Remove-Item -LiteralPath function:\Test-MorpheusSecurePath -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:SpRoot) { Remove-Item -LiteralPath $script:SpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ohne Test-MorpheusSecurePath -> $null, TEMP unveraendert' {
        Get-Command -Name Test-MorpheusSecurePath -CommandType Function -ErrorAction SilentlyContinue | Should BeNullOrEmpty
        Set-MorpheusTempPfad -DataRoot $script:SpRoot | Should BeNullOrEmpty
        $env:TEMP | Should Be $script:TempVorher
        $env:TMP | Should Be $script:TmpVorher
    }
    It 'Sicher=$false -> $null, TEMP unveraendert' {
        function Test-MorpheusSecurePath { param($Path) [pscustomobject]@{ Sicher = $false } }
        New-Item -ItemType Directory -Path $script:SpRoot -Force | Out-Null
        Set-MorpheusTempPfad -DataRoot $script:SpRoot | Should BeNullOrEmpty
        $env:TEMP | Should Be $script:TempVorher
        $env:TMP | Should Be $script:TmpVorher
    }
    It 'Sicher=$true -> <Ordner>\temp\<PID> angelegt, TEMP und TMP zeigen dorthin' {
        function Test-MorpheusSecurePath { param($Path) [pscustomobject]@{ Sicher = $true } }
        New-Item -ItemType Directory -Path $script:SpRoot -Force | Out-Null
        $r = Set-MorpheusTempPfad -DataRoot $script:SpRoot
        $r | Should Be (Join-Path (Join-Path $script:SpRoot 'temp') ([string]$PID))
        [IO.Directory]::Exists($r) | Should Be $true
        $env:TEMP | Should Be $r
        $env:TMP | Should Be $r
    }
}

# ---------------------------------------------------------------- Teil C

Describe 'Kindprozess mit Haertung (Teil C)' {
    It 'Start-Job erbt die gehaertete PSModulePath, nicht die manipulierte' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check-gui.ps1' }
        $haertung = (Get-ErsteAnweisung $f.Ast).Extent.Text
        Test-HaertungStatement (Get-ErsteAnweisung $f.Ast) | Should BeNullOrEmpty
        $befehl = $haertung + "`r`n" + 'Start-Job { $env:PSModulePath } | Wait-Job | Receive-Job'
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($befehl))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $enc
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['PSModulePath'] = 'C:\EvilModules'
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $ausgabe = ''
        try {
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $fertig = $proc.WaitForExit(60000)
            if (-not $fertig) { try { $proc.Kill() } catch { } }
            $fertig | Should Be $true
            $ausgabe = $outTask.Result.Trim()
        }
        finally {
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            $proc.Dispose()
        }
        $ausgabe | Should Not Match 'EvilModules'
        $ausgabe | Should Match ('^' + [regex]::Escape([Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules'))
    }
}

# ---------------------------------------------------------------- Teil D (unabhaengiges Review)

Describe 'Einstiegspunkte: PATH und .NET-Profiler-Variablen (N6)' {
    foreach ($rel in 'pc-check.ps1', 'pc-check-gui.ps1', 'pc-check-start.ps1') {
        It "$rel setzt PATH auf Systemordner und leert COR_/COMPlus_ in den ersten Anweisungen" {
            $f = Get-AdminModel | Where-Object { $_.Rel -eq $rel }
            $erste = @($f.Ast.EndBlock.Statements | Select-Object -First 6)
            $pathZ = @($erste | Where-Object { ($_ -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($_.Left.Extent.Text -eq '$env:PATH') })
            $pathZ.Count | Should Be 1
            $pathZ[0].Right.Extent.Text | Should Match ([regex]::Escape('[Environment]::SystemDirectory'))
            $pathZ[0].Right.Extent.Text | Should Not Match ([regex]::Escape('$env:'))
            @($erste | Where-Object { ($_.Extent.Text -match 'COR_') -and ($_.Extent.Text -match 'COMPlus_') -and ($_.Extent.Text -match 'SetEnvironmentVariable') }).Count | Should Be 1
        }
    }
}

Describe 'pc-check.ps1: Reihenfolge TEMP vor Add-Type' {
    It 'Set-MorpheusTempPfad steht vor jedem Add-Type mit C#-Code' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check.ps1' }
        $set = @($f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Set-MorpheusTempPfad') }, $true))
        $set.Count | Should BeGreaterThan 0
        $setZeile = ($set | ForEach-Object { $_.Extent.StartLineNumber } | Measure-Object -Minimum).Minimum
        $addType = @($f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Add-Type') -and ($n.Extent.Text -match '-(TypeDefinition|MemberDefinition)') }, $true))
        $addType.Count | Should BeGreaterThan 0
        foreach ($a in $addType) { $a.Extent.StartLineNumber | Should BeGreaterThan $setZeile }
    }
}

Describe 'Keine Systemordner aus Umgebungsvariablen in Aktionen und GUI-Bibliotheken' {
    It 'kein $env:SystemDrive/SystemRoot/windir/ProgramFiles/ProgramData als Variable (Anzeigetexte ausgenommen)' {
        $funde = @()
        foreach ($f in Get-AdminModel | Where-Object { $_.Rel -ne 'pc-check.ps1' }) {
            $vars = $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.VariableExpressionAst]) -and ($n.VariablePath.UserPath -match '^env:(SystemDrive|SystemRoot|windir|ProgramFiles|ProgramFiles\(x86\)|ProgramData)$') }, $true)
            foreach ($v in $vars) { $funde += ('{0}:{1} {2}' -f $f.Rel, $v.Extent.StartLineNumber, $v.Extent.Text) }
        }
        ($funde -join "`n") | Should Be ''
    }
}

Describe 'Invoke-Native (pc-check.ps1)' {
    It 'lehnt Namen ohne vollen Laufwerkspfad ab' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check.ps1' }
        $def = $f.Ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Invoke-Native') }, $true)
        $def | Should Not BeNullOrEmpty
        . ([scriptblock]::Create($def.Extent.Text))
        foreach ($x in 'whoami.exe', '\whoami.exe', 'C:whoami.exe', '..\whoami.exe') { { Invoke-Native $x @() } | Should Throw }
        (Invoke-Native ([Environment]::SystemDirectory + '\whoami.exe') @()).Count | Should BeGreaterThan 0
    }
}

Describe 'MorpheusLeereTemp (Install.ps1)' {
    BeforeEach {
        $script:LtRoot = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusLtTest_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:LtRoot -Force | Out-Null
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:LtRoot) {
            Get-ChildItem -LiteralPath $script:LtRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
            Remove-Item -LiteralPath $script:LtRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'behaelt Ordner laufender Prozesse, entfernt Reste und betritt keine Verknuepfung' {
        . (Join-Path $script:Root 'gui\lib\Install.ps1')
        $temp = Join-Path $script:LtRoot 'temp'
        $aussen = Join-Path $script:LtRoot 'aussen'
        New-Item -ItemType Directory -Path (Join-Path $temp ([string]$PID)) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $temp ([string]$PID + '\aktiv.txt')) -Value 'x'
        $alt = Join-Path $temp '4000000000'
        New-Item -ItemType Directory -Path $alt -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $alt 'rest.txt') -Value 'x'
        Set-Content -LiteralPath (Join-Path $temp 'lose.txt') -Value 'x'
        New-Item -ItemType Directory -Path $aussen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $aussen 'bleibt.txt') -Value 'x'
        New-Item -ItemType Junction -Path (Join-Path $alt 'link') -Value $aussen | Out-Null
        MorpheusLeereTemp -Pfad $temp 3>$null
        Test-Path -LiteralPath (Join-Path $temp ([string]$PID + '\aktiv.txt')) | Should Be $true
        Test-Path -LiteralPath $alt | Should Be $false
        Test-Path -LiteralPath (Join-Path $temp 'lose.txt') | Should Be $false
        Test-Path -LiteralPath (Join-Path $aussen 'bleibt.txt') | Should Be $true
    }
    It 'temp selbst als Verknuepfung: nur die Verknuepfung wird entfernt' {
        . (Join-Path $script:Root 'gui\lib\Install.ps1')
        $aussen = Join-Path $script:LtRoot 'aussen'
        New-Item -ItemType Directory -Path $aussen -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $aussen 'bleibt.txt') -Value 'x'
        $temp = Join-Path $script:LtRoot 'temp'
        New-Item -ItemType Junction -Path $temp -Value $aussen | Out-Null
        MorpheusLeereTemp -Pfad $temp 3>$null
        Test-Path -LiteralPath $temp | Should Be $false
        Test-Path -LiteralPath (Join-Path $aussen 'bleibt.txt') | Should Be $true
    }
}

# ---------------------------------------------------------------- Teil E (Nutzertest: Benutzerwerte im GUI-Job-Weg)

Describe 'Benutzer-Temp und Benutzer-PATH im GUI-Job-Weg' {
    It 'ein Job in einem Prozess mit gehaertetem TEMP/PATH liefert die echten Benutzerwerte' {
        $erwTemp = ([Environment]::GetEnvironmentVariable('TEMP', 'User'))
        if (-not $erwTemp) { $erwTemp = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
        $erwTemp = $erwTemp.TrimEnd('\')
        $erwPath = @(([string][Environment]::GetEnvironmentVariable('Path', 'User')) -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ -and ($_ -notmatch '%') })
        # Kein Ordner auf C:\: PowerShell legt ein fehlendes TEMP beim Start an. Deshalb unter dem eigenen Temp, danach loeschen
        $fakeRoot = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusFakeTest_' + [guid]::NewGuid().ToString('N'))
        $fake = Join-Path $fakeRoot '4711'
        $lib = $script:SpFile.Replace("'", "''")
        $befehl = @"
`$j = Start-Job -ScriptBlock { param(`$Lib) . `$Lib; 'TEMP=' + (Get-MorpheusBenutzerTemp); 'EXP=' + (Expand-MorpheusUmgebung '%TEMP%\x.exe'); 'ENV=' + `$env:TEMP; 'PATH=' + (Get-MorpheusBenutzerPath) } -ArgumentList '$lib'
`$j | Wait-Job -Timeout 60 | Out-Null
Receive-Job `$j
Remove-Job `$j -Force
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($befehl))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + $enc
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['TEMP'] = $fake
        $psi.EnvironmentVariables['TMP'] = $fake
        $psi.EnvironmentVariables['PATH'] = [Environment]::SystemDirectory
        $p = [System.Diagnostics.Process]::Start($psi)
        try {
            $outT = $p.StandardOutput.ReadToEndAsync()
            $errT = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch { }; throw 'Kindprozess hat nicht rechtzeitig geantwortet' }
            $zeilen = @(([string]$outT.Result) -split "`r?`n" | Where-Object { $_ })
        }
        finally { $p.Dispose(); if (Test-Path -LiteralPath $fakeRoot) { Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue } }
        $wert = @{}
        foreach ($z in $zeilen) { if ($z -match '^(TEMP|EXP|ENV|PATH)=(.*)$') { $wert[$Matches[1]] = $Matches[2] } }
        # Der Job hat wirklich das gehaertete TEMP geerbt (sonst testet der Fall nichts) ...
        $wert['ENV'] | Should Be $fake
        # ... misst aber den echten Benutzerordner
        $wert['TEMP'] | Should Be $erwTemp
        $wert['EXP'] | Should Be ($erwTemp + '\x.exe')
        $pfade = @($wert['PATH'] -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
        foreach ($e in $erwPath) { $pfade -contains $e | Should Be $true }
        $pfade -contains ([Environment]::SystemDirectory.TrimEnd('\')) | Should Be $true
    }
}

Describe 'pc-check.ps1 misst Benutzerwerte nicht ueber die gehaerteten Prozessvariablen' {
    It 'liest $env:TEMP/TMP/PATH nur am Anfang (Rueckfall) und fuer die secedit-Zwischendatei' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check.ps1' }
        $erlaubt = @($f.Ast.EndBlock.Statements | Select-Object -First 8 | ForEach-Object { $_.Extent.StartLineNumber })
        $funde = @()
        $vars = $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.VariableExpressionAst]) -and ($n.VariablePath.UserPath -match '^env:(TEMP|TMP|PATH)$') }, $true)
        foreach ($v in $vars) {
            $z = $v.Extent.StartLineNumber
            $text = $f.Lines[$z - 1]
            if ($erlaubt -contains $z) { continue }
            if ($text -match 'pc-check-secpol') { continue }
            $funde += ('{0}:{1} {2}' -f $f.Rel, $z, $text.Trim())
        }
        ($funde -join "`n") | Should Be ''
    }
    It 'nutzt ExpandEnvironmentVariables nur im Rueckfall von Expand-MorpheusUmgebung' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check.ps1' }
        $funde = @()
        $aufrufe = $f.Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and ($n.Member.Extent.Text -eq 'ExpandEnvironmentVariables') }, $true)
        foreach ($a in $aufrufe) {
            $fn = $a.Parent
            while ($fn -and ($fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
            if ($fn -and ($fn.Name -eq 'Expand-MorpheusUmgebung')) { continue }
            $funde += ('{0}:{1} {2}' -f $f.Rel, $a.Extent.StartLineNumber, $a.Extent.Text)
        }
        ($funde -join "`n") | Should Be ''
    }
    It 'setzt Benutzer-Temp und Benutzer-PATH aus Get-MorpheusBenutzerTemp/-Path' {
        $f = Get-AdminModel | Where-Object { $_.Rel -eq 'pc-check.ps1' }
        $text = [string]::Join("`n", $f.Lines)
        $text | Should Match ([regex]::Escape('$script:BenutzerTemp = Get-MorpheusBenutzerTemp'))
        $text | Should Match ([regex]::Escape('$script:BenutzerPath = Get-MorpheusBenutzerPath'))
    }
}

# ---------------------------------------------------------------- Teil F (Retest: GUI-Start mit Temp-Resten)
# Initialize-MorpheusDataDir braucht eigentlich Adminrechte. Ersetzt werden nur die Rechte-Bausteine (MorpheusIsAdmin,
# MorpheusCheckAcl, MorpheusIcacls, New-MorpheusSecureDirectory); Aufraeumen, Pruefen und Beiseitelegen laufen echt.
# MorpheusCheckAcl meldet jeden Pfad mit \WinGet als vom Benutzer aenderbar, wie winget ihn in TEMP anlegt.

Describe 'Initialize-MorpheusDataDir mit Temp-Resten eines frueheren Laufs' {
    BeforeEach {
        $script:DdRoot = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusDdTest_' + [guid]::NewGuid().ToString('N'))
        $script:Dd = Join-Path $script:DdRoot 'Morpheus'
        foreach ($d in 'reports', 'changes', 'state', ('temp\' + [string]$PID + '\WinGet\cache'), 'temp\4000000000\WinGet') { New-Item -ItemType Directory -Path (Join-Path $script:Dd $d) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $script:Dd 'reports\pc-check_2026-10-27_0739.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:Dd 'changes\journal.json') -Value '[]'
        Set-Content -LiteralPath (Join-Path $script:Dd ('temp\' + [string]$PID + '\WinGet\cache\index.db')) -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Dd 'temp\4000000000\WinGet\alt.db') -Value 'x'
        $script:IcaclsAufrufe = 0
        $script:BoeseMuster = '\\WinGet'
    }
    AfterEach {
        if ($script:Sperre) { $script:Sperre.Dispose(); $script:Sperre = $null }
        if (Test-Path -LiteralPath $script:DdRoot) { Remove-Item -LiteralPath $script:DdRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    function Use-DdAttrappen {
        . (Join-Path $script:Root 'gui\lib\Install.ps1')
        function MorpheusIsAdmin { $true }
        function MorpheusIcacls { param([string[]]$IcaclsArgs) $script:IcaclsAufrufe++ }
        function New-MorpheusSecureDirectory { param([string]$Path) [void][IO.Directory]::CreateDirectory($Path) }
        function MorpheusCheckAcl {
            param([string]$Path, [int]$Mask, [bool]$CheckOwner, [System.Collections.Generic.List[string]]$Reasons, [string]$Context)
            if ($Path -match $script:BoeseMuster) { $Reasons.Add("Benutzer duerfen $Path aendern") }
        }
    }

    It 'winget-Reste in temp machen den Datenordner nicht unsicher; Ordner beendeter Prozesse werden entfernt' {
        . Use-DdAttrappen
        $r = Initialize-MorpheusDataDir -Path $script:Dd 3>$null
        $r | Should Be $script:Dd
        @(Get-ChildItem -LiteralPath $script:DdRoot -Filter 'Morpheus.unsicher-*').Count | Should Be 0
        $script:IcaclsAufrufe | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:Dd 'reports\pc-check_2026-10-27_0739.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Dd ('temp\' + [string]$PID + '\WinGet\cache\index.db')) | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Dd 'temp\4000000000') | Should Be $false
    }
    It 'Test-MorpheusSecurePath: ohne Ausnahme unsicher, mit -Ausnahmen temp sicher' {
        . Use-DdAttrappen
        (Test-MorpheusSecurePath -Path $script:Dd -Recurse).Sicher | Should Be $false
        (Test-MorpheusSecurePath -Path $script:Dd -Recurse -Ausnahmen 'temp').Sicher | Should Be $true
    }
    It 'echte Luecke ausserhalb von temp wird weiter erkannt und beiseitegelegt' {
        . Use-DdAttrappen
        $script:BoeseMuster = '\\reports\\pc-check_2026'
        $r = Initialize-MorpheusDataDir -Path $script:Dd 3>$null
        $r | Should Be $script:Dd
        @(Get-ChildItem -LiteralPath $script:DdRoot -Filter 'Morpheus.unsicher-*').Count | Should Be 1
        Test-Path -LiteralPath (Join-Path $script:Dd 'reports\pc-check_2026-10-27_0739.json') | Should Be $false
    }
    It 'scheitert das Beiseitelegen, bleibt alles an seinem Ort und es gibt eine klare Meldung' {
        . Use-DdAttrappen
        $script:BoeseMuster = '\\reports\\pc-check_2026'
        $script:Sperre = New-Object IO.FileStream((Join-Path $script:Dd 'changes\journal.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $fehler = $null
        try { Initialize-MorpheusDataDir -Path $script:Dd 3>$null | Out-Null } catch { $fehler = $_.Exception.Message }
        $fehler | Should Match 'unverändert an seinem Ort'
        $fehler | Should Match 'pc-check_2026'
        @(Get-ChildItem -LiteralPath $script:DdRoot -Filter 'Morpheus.unsicher-*').Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:Dd 'reports\pc-check_2026-10-27_0739.json') | Should Be $true
    }
}

Describe 'MorpheusTreeItems -NichtBetreten' {
    It 'liefert den ausgenommenen Ordner, aber nicht seinen Inhalt' {
        . (Join-Path $script:Root 'gui\lib\Install.ps1')
        $w = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusTiTest_' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path (Join-Path $w 'temp\1\WinGet') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $w 'state') -Force | Out-Null
            $namen = @(MorpheusTreeItems -Path $w -NichtBetreten @((Join-Path $w 'temp')) | ForEach-Object { $_.FullName.Substring($w.Length) })
            $namen -contains '\temp' | Should Be $true
            $namen -contains '\state' | Should Be $true
            @($namen | Where-Object { $_ -like '\temp\*' }).Count | Should Be 0
        }
        finally { Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Set-MorpheusTempPfad bei wiederverwendeter Prozess-ID' {
    It 'legt einen vorhandenen Ordner temp\<PID> frisch an und betritt keine Verknuepfung' {
        . (Join-Path $script:Root 'gui\lib\Install.ps1')
        function Test-MorpheusSecurePath { param($Path, [switch]$Recurse, [switch]$NoParents, [string[]]$Ausnahmen) [pscustomobject]@{ Sicher = $true } }
        $w = Join-Path ([IO.Path]::GetTempPath()) ('MorpheusPidTest_' + [guid]::NewGuid().ToString('N'))
        $tempVorher = $env:TEMP; $tmpVorher = $env:TMP
        try {
            $alt = Join-Path $w ('temp\' + [string]$PID)
            New-Item -ItemType Directory -Path (Join-Path $alt 'WinGet') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $alt 'WinGet\alt.txt') -Value 'x'
            $aussen = Join-Path $w 'aussen'
            New-Item -ItemType Directory -Path $aussen -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $aussen 'bleibt.txt') -Value 'x'
            New-Item -ItemType Junction -Path (Join-Path $alt 'link') -Value $aussen | Out-Null
            $r = Set-MorpheusTempPfad -DataRoot $w
            $r | Should Be $alt
            [IO.Directory]::Exists($r) | Should Be $true
            @(Get-ChildItem -LiteralPath $r -Force).Count | Should Be 0
            Test-Path -LiteralPath (Join-Path $aussen 'bleibt.txt') | Should Be $true
        }
        finally {
            $env:TEMP = $tempVorher; $env:TMP = $tmpVorher
            Get-ChildItem -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
            Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
