#Requires -Version 5.1
# Pester-3.4-Tests für gui\lib\Sysinternals.ps1.
# Lädt nichts herunter, nimmt keine EULA an und führt keine Sysinternals-Datei aus:
# Download, Signatur, Wurzel, SicherPfad und Admin sind Attrappen; der Prozessstart wird nur mit cmd.exe getestet.
# Ausführen: Invoke-Pester tests\Sysinternals.Tests.ps1

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:SysFile = Join-Path $PSScriptRoot '..\gui\lib\Sysinternals.ps1'
. $script:SysFile

# Falls die Auswertungsdatei noch fehlt: einfache Attrappe (BOM-Erkennung)
if (-not (Get-Command -Name ConvertFrom-MorpheusSysAusgabe -ErrorAction SilentlyContinue)) {
    function ConvertFrom-MorpheusSysAusgabe {
        param([byte[]]$Bytes)
        if (($null -eq $Bytes) -or ($Bytes.Length -eq 0)) { return '' }
        if (($Bytes.Length -ge 2) -and ($Bytes[0] -eq 0xFF) -and ($Bytes[1] -eq 0xFE)) { return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2) }
        if (($Bytes.Length -ge 3) -and ($Bytes[0] -eq 0xEF) -and ($Bytes[1] -eq 0xBB) -and ($Bytes[2] -eq 0xBF)) { return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3) }
        [Text.Encoding]::UTF8.GetString($Bytes)
    }
}

$script:GoodSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$script:Wurzel2010 = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'
$script:CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'

# Attrappen für Download/Signatur/Wurzel/SicherPfad/Admin
function Set-FakeSys {
    $script:FAdmin = $true
    $script:FSicher = $true
    $script:FUnsicherMuster = $null
    $script:FSigStatus = 'Valid'
    $script:FSubject = $script:GoodSubject
    $script:FWurzel = $script:Wurzel2010
    $script:FHerkunft = [pscustomobject]@{ CompanyName = 'Sysinternals - www.sysinternals.com'; ProductName = 'Sysinternals Autoruns' }
    $script:FDownloads = New-Object System.Collections.ArrayList
    $script:FZips = @{}
    $script:FDownloadFehler = $null
    $script:MorpheusSysExeMaxBytes = 30MB
    $script:MorpheusSysImpl = @{
        Download   = {
            param($Url, $Ziel, $MaxBytes)
            [void]$script:FDownloads.Add($Url)
            if ($script:FDownloadFehler) { throw $script:FDownloadFehler }
            Copy-Item -LiteralPath $script:FZips[$Url] -Destination $Ziel -Force
        }
        Signatur   = { param($Pfad) [pscustomobject]@{ Status = $script:FSigStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:FSubject } } }
        Wurzel     = { param($Zertifikat, $Pfad) $script:FWurzel }
        Herkunft   = { param($Pfad) $script:FHerkunft }
        SicherPfad = {
            param($Pfad)
            if (($script:FSicher) -and (-not ($script:FUnsicherMuster -and ($Pfad -match $script:FUnsicherMuster)))) { @{ Sicher = $true; Gruende = @() } } else { @{ Sicher = $false; Gruende = @('S-1-5-11 darf schreiben') } }
        }
        Admin      = { $script:FAdmin }
    }
}

function New-FakeZip {
    # entries: Name -> Text (Namen werden unverändert als FullName eingetragen)
    param([string]$Pfad, [System.Collections.Specialized.OrderedDictionary]$Entries)
    $fs = [IO.File]::Create($Pfad)
    try {
        $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($k in $Entries.Keys) {
                $e = $za.CreateEntry($k)
                $s = $e.Open()
                try { $b = [Text.Encoding]::UTF8.GetBytes([string]$Entries[$k]); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
            }
        } finally { $za.Dispose() }
    } finally { $fs.Dispose() }
}

function New-Sandbox {
    # Datenordner mit tools und state; die ZIP-Attrappen werden angelegt und den URLs zugeordnet
    param([switch]$OhneTools, [switch]$SlipEintraege)
    $root = Join-Path $TestDrive ('d' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force | Out-Null
    if (-not $OhneTools) { New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null }
    $zdir = Join-Path $root 'zips'
    New-Item -ItemType Directory -Path $zdir -Force | Out-Null
    foreach ($n in 'autorunsc', 'sigcheck') {
        $def = $script:MorpheusSysWerkzeuge[$n]
        $e = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        if ($SlipEintraege) {
            $e['..\evil.exe'] = 'EVIL'
            $e['../evil2.exe'] = 'EVIL'
            $e['sub\' + $def.Exe] = 'EVIL'
            $e['sub/' + $def.Exe] = 'EVIL'
            $e['Readme.txt'] = 'EVIL'
        }
        $e[$def.Exe] = 'GOODEXE-' + $n
        $e['Eula.txt'] = 'EULA-TEXT-' + $n
        $zp = Join-Path $zdir $def.Zip
        New-FakeZip -Pfad $zp -Entries $e
        $script:FZips[$def.Url] = $zp
    }
    $root
}

function Install-Fake {
    param([string]$Root)
    [void](Set-MorpheusSysZustimmung -DataRoot $Root -Akzeptiert $true)
    Install-MorpheusSysWerkzeuge -DataRoot $Root 6>$null
}

Describe 'Sysinternals.ps1: Datei' {
    It 'hat UTF-8-BOM' {
        $b = [IO.File]::ReadAllBytes($script:SysFile)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
    }
    It 'lässt sich fehlerfrei parsen' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $script:SysFile).Path, [ref]$null, [ref]$errors)
        @($errors).Count | Should Be 0
    }
    It 'verwendet Add-Type nur für Assemblys, nie mit C#-Code' {
        $text = Get-Content -LiteralPath $script:SysFile -Raw
        $text | Should Not Match 'TypeDefinition'
        $text | Should Not Match '-MemberDefinition'
        foreach ($m in [regex]::Matches($text, 'Add-Type\s+-[^\r\n]*')) { $m.Value | Should Match '-AssemblyName System\.IO\.Compression\.FileSystem' }
    }
    It 'enthält nirgends die VirusTotal-Schalter' {
        $text = Get-Content -LiteralPath $script:SysFile -Raw
        foreach ($v in '-v', '-vt', '-vr', '-vs') { $text | Should Not Match ("'" + $v + "'") }
    }
    It 'bringt Standard-Impl mit allen fünf Einträgen' {
        $keep = $script:MorpheusSysImpl
        try {
            $impl = & { $script:MorpheusSysImpl = $null; . $script:SysFile; $script:MorpheusSysImpl }
        } finally { $script:MorpheusSysImpl = $keep }
        foreach ($k in 'Download', 'Signatur', 'Wurzel', 'Herkunft', 'SicherPfad', 'Admin') { ($impl[$k] -is [scriptblock]) | Should Be $true }
    }
    It 'Standard-Download erlaubt nur https://download.sysinternals.com/files/ (ohne Netzzugriff)' {
        $keep = $script:MorpheusSysImpl
        try {
            $impl = & { $script:MorpheusSysImpl = $null; . $script:SysFile; $script:MorpheusSysImpl }
        } finally { $script:MorpheusSysImpl = $keep }
        $ziel = Join-Path $TestDrive 'nie.zip'
        foreach ($u in 'http://download.sysinternals.com/files/Autoruns.zip', 'https://evil.example/files/Autoruns.zip',
            'https://download.sysinternals.com.evil.example/files/Autoruns.zip', 'HTTPS://download.sysinternals.com/files/Autoruns.zip',
            'https://download.sysinternals.com/other/Autoruns.zip', '') {
            { & $impl.Download $u $ziel 1000 } | Should Throw 'nicht erlaubt'
        }
        Test-Path -LiteralPath $ziel | Should Be $false
    }
    It 'Konstanten: Urls, Dateien und Wurzeln' {
        $script:MorpheusSysWerkzeuge['autorunsc'].Url | Should Be 'https://download.sysinternals.com/files/Autoruns.zip'
        $script:MorpheusSysWerkzeuge['sigcheck'].Url | Should Be 'https://download.sysinternals.com/files/Sigcheck.zip'
        $script:MorpheusSysWerkzeuge['autorunsc'].Exe | Should Be 'autorunsc64.exe'
        $script:MorpheusSysWerkzeuge['sigcheck'].Exe | Should Be 'sigcheck64.exe'
        @($script:MorpheusSysWurzeln).Count | Should Be 2
        $script:MorpheusSysLizenzUrl | Should Be 'https://learn.microsoft.com/sysinternals/license-terms'
    }
}

Describe 'MorpheusSysArgumente' {
    It 'autostarts: autorunsc mit festen Argumenten' {
        $a = MorpheusSysArgumente -Auftrag 'autostarts'
        $a.Name | Should Be 'autorunsc'
        ($a.Argumente -join ' ') | Should Be '-accepteula -nobanner -a * -c -s *'
    }
    It 'system32: sigcheck mit System32-Ordner' {
        $a = MorpheusSysArgumente -Auftrag 'system32'
        $a.Name | Should Be 'sigcheck'
        ($a.Argumente -join ' ') | Should Be ('-accepteula -nobanner -c -u -e -r ' + (Join-Path $env:SystemRoot 'System32'))
    }
    It 'treiber: sigcheck mit drivers-Ordner' {
        $a = MorpheusSysArgumente -Auftrag 'treiber'
        $a.Name | Should Be 'sigcheck'
        ($a.Argumente -join ' ') | Should Be ('-accepteula -nobanner -c -u -e -r ' + (Join-Path $env:SystemRoot 'System32\drivers'))
    }
    It 'enthält nie -v*, nie -h, aber immer -accepteula und -nobanner' {
        foreach ($auf in 'autostarts', 'system32', 'treiber') {
            $a = MorpheusSysArgumente -Auftrag $auf
            @($a.Argumente | Where-Object { $_ -match '^-v' }).Count | Should Be 0
            ($a.Argumente -contains '-h') | Should Be $false
            ($a.Argumente -contains '-accepteula') | Should Be $true
            ($a.Argumente -contains '-nobanner') | Should Be $true
        }
    }
    It 'wirft bei unbekanntem Auftrag (auch bei anderer Schreibweise oder leer)' {
        foreach ($x in 'virustotal', 'AUTOSTARTS', '', 'autostarts -vt') {
            { MorpheusSysArgumente -Auftrag $x } | Should Throw 'Unbekannter'
        }
    }
}

Describe 'MorpheusSysArgString' {
    It 'quotet nur bei Leerzeichen oder Anführungszeichen' {
        MorpheusSysArgString -Argumente @('-a', '*', 'C:\Windows\System32') | Should Be '-a * C:\Windows\System32'
        MorpheusSysArgString -Argumente @('C:\a b\c') | Should Be '"C:\a b\c"'
    }
    It 'verdoppelt abschließende Backslashes und maskiert Anführungszeichen' {
        MorpheusSysArgString -Argumente @('C:\a b\') | Should Be '"C:\a b\\"'
        MorpheusSysArgString -Argumente @('x"y') | Should Be '"x\"y"'
        MorpheusSysArgString -Argumente @('') | Should Be '""'
    }
}

Describe 'Zustimmung' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox }

    It 'fehlende Datei: nicht akzeptiert' {
        $z = Get-MorpheusSysZustimmung -DataRoot $script:Root
        $z.akzeptiert | Should Be $false
    }
    It 'schreiben und lesen' {
        $z = Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true
        $z.akzeptiert | Should Be $true
        $z.benutzer | Should Be ([Environment]::UserName)
        $z.zeit | Should Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$'
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $true
    }
    It 'Datei: UTF-8 ohne BOM, richtige Felder, kein .tmp-Rest' {
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true)
        $p = Join-Path $script:Root 'state\sysinternals.json'
        $b = [IO.File]::ReadAllBytes($p)
        (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB)) | Should Be $false
        $j = [Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json
        $j.version | Should Be 1
        $j.eulaAkzeptiert | Should Be $true
        Test-Path -LiteralPath ($p + '.tmp') | Should Be $false
    }
    It 'zweites Schreiben ersetzt die Datei' {
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true)
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true)
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $true
    }
    It 'löschen (Akzeptiert false) entfernt die Datei' {
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true)
        $z = Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $false
        $z.akzeptiert | Should Be $false
        Test-Path -LiteralPath (Join-Path $script:Root 'state\sysinternals.json') | Should Be $false
    }
    It 'Löschen ohne vorhandene Datei ist kein Fehler' {
        (Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $false).akzeptiert | Should Be $false
    }
    It 'legt einen fehlenden state-Ordner beim Schreiben an' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'state') -Recurse -Force
        (Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true).akzeptiert | Should Be $true
    }
    It 'kaputte Datei: nicht akzeptiert' {
        Set-Content -LiteralPath (Join-Path $script:Root 'state\sysinternals.json') -Value '{ das ist kein json'
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $false
    }
    It 'Wert ist keine echte Boolean true: nicht akzeptiert' {
        $p = Join-Path $script:Root 'state\sysinternals.json'
        Set-Content -LiteralPath $p -Value '{ "version": 1, "eulaAkzeptiert": "true", "zeit": "2026-10-26T10:00:00", "benutzer": "x" }'
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $false
        Set-Content -LiteralPath $p -Value '{ "version": 1, "eulaAkzeptiert": false }'
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $false
        Set-Content -LiteralPath $p -Value '{ "version": 1 }'
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $false
    }
    It 'unsicher abgelegte Datei zählt nicht' {
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $true)
        $script:FSicher = $false
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $false
    }
}

Describe 'Install-MorpheusSysWerkzeuge' {
    BeforeEach { Set-FakeSys }
    AfterEach { $script:MorpheusSysExeMaxBytes = 30MB }

    It 'richtet beide Werkzeuge ein, schreibt werkzeuge.json und Eula, räumt auf' {
        $root = New-Sandbox
        $r = Install-Fake -Root $root
        $tools = Join-Path $root 'tools'
        @($r.werkzeuge).Count | Should Be 2
        $r.werkzeuge[0].geprueft | Should Be $true
        $r.werkzeuge[1].geprueft | Should Be $true
        [string]$r.meldung | Should Not BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $tools 'autorunsc64.exe')) | Should Be 'GOODEXE-autorunsc'
        [IO.File]::ReadAllText((Join-Path $tools 'sigcheck64.exe')) | Should Be 'GOODEXE-sigcheck'
        [IO.File]::ReadAllText((Join-Path $tools 'autorunsc-Eula.txt')) | Should Be 'EULA-TEXT-autorunsc'
        [IO.File]::ReadAllText((Join-Path $tools 'sigcheck-Eula.txt')) | Should Be 'EULA-TEXT-sigcheck'
        $j = [IO.File]::ReadAllText((Join-Path $tools 'werkzeuge.json')) | ConvertFrom-Json
        $j.version | Should Be 1
        $j.werkzeuge.autorunsc.datei | Should Be 'autorunsc64.exe'
        $j.werkzeuge.autorunsc.sha256 | Should Match '^[0-9a-f]{64}$'
        $j.werkzeuge.sigcheck.sha256 | Should Match '^[0-9a-f]{64}$'
        ($j.werkzeuge.autorunsc.sha256 -ne $j.werkzeuge.sigcheck.sha256) | Should Be $true
        @(Get-ChildItem -LiteralPath $tools -Force | Where-Object { $_.Name -match '\.(download|neu\.exe|neu|tmp)$' }).Count | Should Be 0
        $script:FDownloads.Count | Should Be 2
        $script:FDownloads[0] | Should Be 'https://download.sysinternals.com/files/Autoruns.zip'
        $script:FDownloads[1] | Should Be 'https://download.sysinternals.com/files/Sigcheck.zip'
    }

    It 'werkzeuge.json ist UTF-8 ohne BOM' {
        $root = New-Sandbox
        [void](Install-Fake -Root $root)
        $b = [IO.File]::ReadAllBytes((Join-Path $root 'tools\werkzeuge.json'))
        (($b[0] -eq 0xEF) -and ($b[1] -eq 0xBB)) | Should Be $false
    }

    It 'entpackt keine Zip-Slip- oder Pfad-Einträge und nur den exakten Namen' {
        $root = New-Sandbox -SlipEintraege
        [void](Install-Fake -Root $root)
        $tools = Join-Path $root 'tools'
        $namen = @(Get-ChildItem -LiteralPath $tools -Force | ForEach-Object { $_.Name })
        ($namen | Sort-Object) -join ',' | Should Be 'autorunsc64.exe,autorunsc-Eula.txt,sigcheck64.exe,sigcheck-Eula.txt,werkzeuge.json'
        Test-Path -LiteralPath (Join-Path $root 'evil.exe') | Should Be $false
        Test-Path -LiteralPath (Join-Path $root 'evil2.exe') | Should Be $false
        Test-Path -LiteralPath (Join-Path $tools 'sub') | Should Be $false
        Test-Path -LiteralPath (Join-Path $tools 'Readme.txt') | Should Be $false
        [IO.File]::ReadAllText((Join-Path $tools 'autorunsc64.exe')) | Should Be 'GOODEXE-autorunsc'
    }

    It 'bricht ab, wenn nur Einträge mit Pfadanteil vorhanden sind' {
        $root = New-Sandbox
        $e = [ordered]@{ 'sub\autorunsc64.exe' = 'EVIL'; '..\autorunsc64.exe' = 'EVIL'; 'sub/autorunsc64.exe' = 'EVIL'; 'Eula.txt' = 'x' }
        New-FakeZip -Pfad $script:FZips['https://download.sysinternals.com/files/Autoruns.zip'] -Entries $e
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'autorunsc64.exe'
        Test-Path -LiteralPath (Join-Path $root 'tools\autorunsc64.exe') | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force | Where-Object { $_.Name -match '\.(download|neu\.exe|neu)$' }).Count | Should Be 0
    }

    It 'akzeptiert andere Groß-/Kleinschreibung und entpackt unter dem festen Namen' {
        $root = New-Sandbox
        $e = [ordered]@{ 'Autorunsc64.EXE' = 'GOODEXE-autorunsc'; 'EULA.txt' = 'EULA-TEXT-autorunsc' }
        New-FakeZip -Pfad $script:FZips['https://download.sysinternals.com/files/Autoruns.zip'] -Entries $e
        [void](Install-Fake -Root $root)
        $namen = @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force | ForEach-Object { $_.Name })
        ($namen -ccontains 'autorunsc64.exe') | Should Be $true
        ($namen -ccontains 'Autorunsc64.EXE') | Should Be $false
    }

    It 'zwei Treffer in verschiedener Schreibweise sind ein Fehler' {
        $root = New-Sandbox
        $zp = $script:FZips['https://download.sysinternals.com/files/Autoruns.zip']
        Remove-Item -LiteralPath $zp -Force
        $fs = [IO.File]::Create($zp)
        $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($n in 'autorunsc64.exe', 'AUTORUNSC64.exe') { $s = $za.CreateEntry($n).Open(); $s.WriteByte(65); $s.Dispose() }
        $za.Dispose(); $fs.Dispose()
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'genau einem'
        Test-Path -LiteralPath (Join-Path $root 'tools\autorunsc64.exe') | Should Be $false
    }

    It 'bricht bei doppeltem exaktem Eintrag ab' {
        $root = New-Sandbox
        $zp = $script:FZips['https://download.sysinternals.com/files/Autoruns.zip']
        Remove-Item -LiteralPath $zp -Force
        $fs = [IO.File]::Create($zp)
        $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($i in 1, 2) { $s = $za.CreateEntry('autorunsc64.exe').Open(); $s.WriteByte(65); $s.Dispose() }
        $za.Dispose(); $fs.Dispose()
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw
        Test-Path -LiteralPath (Join-Path $root 'tools\autorunsc64.exe') | Should Be $false
    }

    It 'bricht bei zu großem Eintrag ab und räumt auf' {
        $root = New-Sandbox
        $script:MorpheusSysExeMaxBytes = 5
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'größer als erlaubt'
        $tools = Join-Path $root 'tools'
        @(Get-ChildItem -LiteralPath $tools -Force).Count | Should Be 0
    }

    It 'wirft ohne Adminrechte, ohne etwas zu laden' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FAdmin = $false
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'Administrator'
        $script:FDownloads.Count | Should Be 0
    }

    It 'wirft ohne Zustimmung, ohne etwas zu laden' {
        $root = New-Sandbox
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'Lizenz'
        $script:FDownloads.Count | Should Be 0
    }

    It 'benutzt einen vorhandenen, unsicheren tools-Ordner nicht' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FUnsicherMuster = '\\tools$'
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'nicht nur für Administratoren'
        $script:FDownloads.Count | Should Be 0
    }

    It 'legt einen fehlenden tools-Ordner mit New-MorpheusSecureDirectory an' {
        Mock New-MorpheusSecureDirectory { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $root = New-Sandbox -OhneTools
        $r = Install-Fake -Root $root
        Assert-MockCalled New-MorpheusSecureDirectory -Times 1 -Exactly
        @($r.werkzeuge).Count | Should Be 2
        Test-Path -LiteralPath (Join-Path $root 'tools\autorunsc64.exe') | Should Be $true
    }

    It 'Signatur ungültig: wirft, keine EXE und keine Reste' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FSigStatus = 'HashMismatch'
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'nicht vertrauenswürdig'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force).Count | Should Be 0
    }

    It 'falscher Signierer: wirft' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FSubject = 'CN=Evil Corp, O=Evil Corp, C=US'
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'Microsoft Corporation'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force).Count | Should Be 0
    }

    It 'falsche Wurzel: wirft' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FWurzel = 'AAAA'
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'Stammzertifizierungsstelle'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force).Count | Should Be 0
    }

    It 'Download-Fehler: wirft mit Meldung, räumt auf' {
        $root = New-Sandbox
        [void](Set-MorpheusSysZustimmung -DataRoot $root -Akzeptiert $true)
        $script:FDownloadFehler = 'Kein Netz'
        { Install-MorpheusSysWerkzeuge -DataRoot $root } | Should Throw 'Kein Netz'
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Force).Count | Should Be 0
    }

    It 'ersetzt vorhandene Dateien bei erneutem Bezug' {
        $root = New-Sandbox
        [void](Install-Fake -Root $root)
        $r = Install-Fake -Root $root
        $r.werkzeuge[0].geprueft | Should Be $true
    }
}

Describe 'Test-MorpheusSysWerkzeug' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox; [void](Install-Fake -Root $script:Root) }
    AfterEach { $script:MorpheusSysExeMaxBytes = 30MB }

    It 'liefert alle Felder; geprüfte Datei hat keinen Grund' {
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $names = @($w.PSObject.Properties | ForEach-Object { $_.Name })
        ($names -join ',') | Should Be 'name,titel,datei,pfad,vorhanden,geprueft,grund,signierer,version,sha256,geladen'
        $w.name | Should Be 'autorunsc'
        $w.titel | Should Be 'Autoruns'
        $w.datei | Should Be 'autorunsc64.exe'
        $w.pfad | Should Be (Join-Path $script:Root 'tools\autorunsc64.exe')
        $w.vorhanden | Should Be $true
        $w.geprueft | Should Be $true
        $w.grund | Should BeNullOrEmpty
        $w.signierer | Should Be 'Microsoft Corporation'
        $w.sha256 | Should Match '^[0-9a-f]{64}$'
        $w.geladen | Should Match '^\d{4}-\d\d-\d\dT'
    }
    It 'Datei fehlt' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'tools\autorunsc64.exe') -Force
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.vorhanden | Should Be $false
        $w.geprueft | Should Be $false
        $w.grund | Should Be 'Die Datei autorunsc64.exe fehlt.'
    }
    It 'Signatur ungültig' {
        $script:FSigStatus = 'HashMismatch'
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name sigcheck
        $w.vorhanden | Should Be $true
        $w.geprueft | Should Be $false
        $w.grund | Should Be 'Die Signatur ist ungültig (Status: HashMismatch).'
    }
    It 'Signierer Evil Corp' {
        $script:FSubject = 'CN=Evil Corp, O=Evil Corp, C=US'
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match 'nicht von Microsoft Corporation'
    }
    It 'Signierer, der Microsoft nur enthält, reicht nicht' {
        foreach ($s in 'CN=Microsoft Corporation, O=Microsoft Corporation Fake Ltd, C=US', 'CN=x, O=Evil, OU=Microsoft Corporation', 'O=microsoft corporation') {
            $script:FSubject = $s
            (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $false
        }
    }
    It 'Subject mit O in Anführungszeichen wird akzeptiert' {
        $script:FSubject = 'CN="Microsoft Corporation", O="Microsoft Corporation", C=US'
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $true
    }
    It 'falsche oder fehlende Wurzel' {
        $script:FWurzel = '0000000000000000000000000000000000000000'
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match 'Stammzertifizierungsstelle'
        $script:FWurzel = $null
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $false
    }
    It 'Wurzel 2011 und Kleinschreibung werden akzeptiert' {
        $script:FWurzel = '8f43288ad272f3103b6fb1428485ea3014c0bcfe'
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $true
    }
    It 'anderes, von Microsoft signiertes Programm unter Sysinternals-Namen wird abgelehnt' {
        $script:FHerkunft = [pscustomobject]@{ CompanyName = 'Microsoft Corporation'; ProductName = 'Microsoft Windows Operating System' }
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Be 'Die Datei ist kein Sysinternals-Programm (Firma: Microsoft Corporation, Produkt: Microsoft Windows Operating System).'
        $script:FHerkunft = $null
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $false
    }
    It 'Sysinternals nur im Produktnamen reicht' {
        $script:FHerkunft = [pscustomobject]@{ CompanyName = ''; ProductName = 'Sysinternals Sigcheck' }
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $true
    }
    It 'unsicherer Pfad' {
        $script:FUnsicherMuster = '\\tools$'
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match '^Der Ordner ist nicht nur für Administratoren beschreibbar: '
    }
    It 'Hash-Abweichung zu werkzeuge.json' {
        [IO.File]::WriteAllText((Join-Path $script:Root 'tools\autorunsc64.exe'), 'MANIPULIERT')
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Be 'Die Datei wurde seit dem Download verändert (SHA256 passt nicht).'
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name sigcheck).geprueft | Should Be $true
    }
    It 'werkzeuge.json fehlt' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'tools\werkzeuge.json') -Force
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match 'werkzeuge.json'
    }
    It 'werkzeuge.json kaputt oder ohne Eintrag' {
        $p = Join-Path $script:Root 'tools\werkzeuge.json'
        Set-Content -LiteralPath $p -Value '{ kaputt'
        (Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc).geprueft | Should Be $false
        Set-Content -LiteralPath $p -Value '{ "version": 1, "werkzeuge": { "sigcheck": { "datei": "sigcheck64.exe", "sha256": "00" } } }'
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match 'Eintrag'
    }
    It 'werkzeuge.json unsicher abgelegt' {
        $script:FSicher = $false
        $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
        $w.geprueft | Should Be $false
    }
    It 'Datei wird von anderem Prozess zum Schreiben offen gehalten: nicht prüfbar' {
        $fs = New-Object IO.FileStream((Join-Path $script:Root 'tools\autorunsc64.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $w = Test-MorpheusSysWerkzeug -DataRoot $script:Root -Name autorunsc
            $w.geprueft | Should Be $false
            $w.grund | Should Match 'ließ sich nicht öffnen'
        } finally { $fs.Dispose() }
    }
    It 'tools als Verknüpfung (Junction) wird abgelehnt' {
        $echt = Join-Path $script:Root 'tools'
        $root2 = Join-Path $TestDrive ('j' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root2 -Force | Out-Null
        $out = & $env:ComSpec /c mklink /J ('"' + (Join-Path $root2 'tools') + '"') ('"' + $echt + '"') 2>&1
        if (-not (Test-Path -LiteralPath (Join-Path $root2 'tools'))) { Set-TestInconclusive 'Junction ließ sich nicht anlegen'; return }
        $w = Test-MorpheusSysWerkzeug -DataRoot $root2 -Name autorunsc
        $w.geprueft | Should Be $false
        $w.grund | Should Match 'Verknüpfung'
        & $env:ComSpec /c rmdir ('"' + (Join-Path $root2 'tools') + '"') | Out-Null
    }
}

Describe 'Get-MorpheusSysStand' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox }

    It 'hat die vereinbarte Form (nichts eingerichtet)' {
        $s = Get-MorpheusSysStand -DataRoot $script:Root
        (@($s.Keys) -join ',') | Should Be 'zustimmung,werkzeuge,ordner,lizenzUrl'
        $s.zustimmung.akzeptiert | Should Be $false
        @($s.werkzeuge).Count | Should Be 2
        $s.werkzeuge[0].name | Should Be 'autorunsc'
        $s.werkzeuge[1].name | Should Be 'sigcheck'
        $s.werkzeuge[0].vorhanden | Should Be $false
        $s.ordner | Should Be (Join-Path $script:Root 'tools')
        $s.lizenzUrl | Should Be 'https://learn.microsoft.com/sysinternals/license-terms'
    }
    It 'nach dem Einrichten geprüft; ConvertTo-Json funktioniert' {
        [void](Install-Fake -Root $script:Root)
        $s = Get-MorpheusSysStand -DataRoot $script:Root
        $s.zustimmung.akzeptiert | Should Be $true
        $s.werkzeuge[0].geprueft | Should Be $true
        $json = $s | ConvertTo-Json -Depth 6
        $back = $json | ConvertFrom-Json
        @($back.werkzeuge).Count | Should Be 2
    }
}

Describe 'Remove-MorpheusSysWerkzeuge' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox; [void](Install-Fake -Root $script:Root) }

    It 'löscht Exe, Eula, werkzeuge.json und Zustimmung und gibt den Stand zurück' {
        $s = Remove-MorpheusSysWerkzeuge -DataRoot $script:Root
        @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'tools') -Force).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $script:Root 'state\sysinternals.json') | Should Be $false
        $s.zustimmung.akzeptiert | Should Be $false
        $s.werkzeuge[0].vorhanden | Should Be $false
        $s.werkzeuge[1].vorhanden | Should Be $false
    }
    It 'lässt fremde Dateien im tools-Ordner stehen' {
        Set-Content -LiteralPath (Join-Path $script:Root 'tools\fremd.txt') -Value 'x'
        [void](Remove-MorpheusSysWerkzeuge -DataRoot $script:Root)
        Test-Path -LiteralPath (Join-Path $script:Root 'tools\fremd.txt') | Should Be $true
    }
    It 'ist ohne vorhandene Dateien ein Nullbefehl' {
        [void](Remove-MorpheusSysWerkzeuge -DataRoot $script:Root)
        { Remove-MorpheusSysWerkzeuge -DataRoot $script:Root } | Should Not Throw
    }
    It 'meldet eine gesperrte Datei deutlich und löscht dann weder Metadaten noch Zustimmung' {
        $tools = Join-Path $script:Root 'tools'
        $fs = [IO.File]::Open((Join-Path $tools 'autorunsc64.exe'), 'Open', 'Read', 'Read')
        try { { Remove-MorpheusSysWerkzeuge -DataRoot $script:Root } | Should Throw 'wird gerade verwendet' } finally { $fs.Dispose() }
        Test-Path -LiteralPath (Join-Path $tools 'werkzeuge.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $tools 'autorunsc-Eula.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Root 'state\sysinternals.json') | Should Be $true
        (Get-MorpheusSysZustimmung -DataRoot $script:Root).akzeptiert | Should Be $true
    }
}

Describe 'Get-MorpheusSysEula' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox }

    It 'fehlende Datei oder unbekannter Name: $null' {
        Get-MorpheusSysEula -DataRoot $script:Root -Name autorunsc | Should BeNullOrEmpty
        [void](Install-Fake -Root $script:Root)
        Get-MorpheusSysEula -DataRoot $script:Root -Name 'Autorunsc' | Should BeNullOrEmpty
        Get-MorpheusSysEula -DataRoot $script:Root -Name '..\werkzeuge' | Should BeNullOrEmpty
    }
    It 'liefert den Text' {
        [void](Install-Fake -Root $script:Root)
        Get-MorpheusSysEula -DataRoot $script:Root -Name autorunsc | Should Be 'EULA-TEXT-autorunsc'
    }
    It 'kürzt Texte über 64 KB (erste 64 KB plus Hinweis)' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'tools') -Force | Out-Null
        $p = Join-Path $script:Root 'tools\sigcheck-Eula.txt'
        [IO.File]::WriteAllText($p, ('A' * 100000))
        $t = Get-MorpheusSysEula -DataRoot $script:Root -Name sigcheck
        $t | Should Match 'gekürzt'
        $t.Length | Should BeLessThan 70000
        $t.Length | Should BeGreaterThan 65000
    }
    It 'erkennt UTF-16 mit BOM' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'tools') -Force | Out-Null
        $p = Join-Path $script:Root 'tools\autorunsc-Eula.txt'
        [IO.File]::WriteAllText($p, 'Lizenz Ünicode', [Text.Encoding]::Unicode)
        Get-MorpheusSysEula -DataRoot $script:Root -Name autorunsc | Should Be 'Lizenz Ünicode'
    }
}

Describe 'MorpheusSysStart (nur cmd.exe)' {
    It 'liest die Ausgabe als Bytes' {
        $r = MorpheusSysStart -Exe $script:CmdExe -Argumente @('/c', 'echo', 'hallo') -TimeoutSek 30
        $r.ok | Should Be $true
        $r.code | Should Be 0
        $r.zeitueberschreitung | Should Be $false
        (ConvertFrom-MorpheusSysAusgabe -Bytes $r.ausgabe).Trim() | Should Be 'hallo'
        ($r.ausgabe -is [byte[]]) | Should Be $true
    }
    It 'liefert Exitcode und Fehlerausgabe' {
        $r = MorpheusSysStart -Exe $script:CmdExe -Argumente @('/c', 'exit', '3') -TimeoutSek 30
        $r.ok | Should Be $true
        $r.code | Should Be 3
        $r = MorpheusSysStart -Exe $script:CmdExe -Argumente @('/c', 'echo fehler 1>&2') -TimeoutSek 30
        (ConvertFrom-MorpheusSysAusgabe -Bytes $r.fehlerAusgabe) | Should Match 'fehler'
    }
    It 'Arbeitsordner wird verwendet' {
        $d = Join-Path $TestDrive 'wd'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = MorpheusSysStart -Exe $script:CmdExe -Argumente @('/c', 'cd') -TimeoutSek 30 -Arbeitsordner $d
        (ConvertFrom-MorpheusSysAusgabe -Bytes $r.ausgabe).Trim() | Should Be $d
    }
    It 'gesperrte Datei lässt sich während des Laufs weder schreiben, löschen noch umbenennen' {
        $kopie = Join-Path $TestDrive 'gesperrt-cmd.exe'
        Copy-Item -LiteralPath $script:CmdExe -Destination $kopie
        $script:LockRes = @{ Schreiben = 'nicht versucht'; Loeschen = 'nicht versucht'; Umbenennen = 'nicht versucht'; Lesen = 'nicht versucht' }
        $stream = MorpheusSysOeffnen $kopie
        try {
            $r = MorpheusSysStart -Exe $kopie -Argumente @('/c', 'ping', '-n', '3', '127.0.0.1', '>nul') -TimeoutSek 60 -Stream $stream -ImLauf {
                param($ProzessId, $Stream)
                try { $w = [IO.File]::Open($kopie, 'Open', 'Write', 'ReadWrite'); $w.Dispose(); $script:LockRes.Schreiben = 'ok' } catch { $script:LockRes.Schreiben = 'gesperrt' }
                try { [IO.File]::Delete($kopie); $script:LockRes.Loeschen = if (Test-Path -LiteralPath $kopie) { 'gesperrt' } else { 'geloescht' } } catch { $script:LockRes.Loeschen = 'gesperrt' }
                try { [IO.File]::Move($kopie, $kopie + '.x'); $script:LockRes.Umbenennen = 'umbenannt' } catch { $script:LockRes.Umbenennen = 'gesperrt' }
                try { $l = [IO.File]::Open($kopie, 'Open', 'Read', 'Read'); $l.Dispose(); $script:LockRes.Lesen = 'ok' } catch { $script:LockRes.Lesen = 'gesperrt' }
            }
        } finally { $stream.Dispose() }
        $r.ok | Should Be $true
        $r.code | Should Be 0
        $script:LockRes.Schreiben | Should Be 'gesperrt'
        $script:LockRes.Loeschen | Should Be 'gesperrt'
        $script:LockRes.Umbenennen | Should Be 'gesperrt'
        $script:LockRes.Lesen | Should Be 'ok'
        # nach dem Schließen wieder frei
        $w = [IO.File]::Open($kopie, 'Open', 'Write', 'ReadWrite'); $w.Dispose()
    }
    It 'Zeitlimit beendet den Prozess' {
        $script:PidTimeout = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = MorpheusSysStart -Exe $script:CmdExe -Argumente @('/c', 'ping', '-n', '30', '127.0.0.1', '>nul') -TimeoutSek 1 -ImLauf { param($ProzessId, $Stream) $script:PidTimeout = $ProzessId }
        $sw.Stop()
        $r.ok | Should Be $false
        $r.zeitueberschreitung | Should Be $true
        $r.fehler | Should Match 'Zeitüberschreitung'
        $sw.Elapsed.TotalSeconds | Should BeLessThan 15
        $script:PidTimeout | Should BeGreaterThan 0
        @(Get-Process -Id $script:PidTimeout -ErrorAction SilentlyContinue).Count | Should Be 0
    }
    It 'nicht startbare Datei: ok false, kein Wurf' {
        $r = MorpheusSysStart -Exe (Join-Path $TestDrive 'gibt-es-nicht.exe') -Argumente @() -TimeoutSek 5
        $r.ok | Should Be $false
        $r.fehler | Should Match 'nicht starten'
    }
}

Describe 'Invoke-MorpheusSysWerkzeug' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox; [void](Install-Fake -Root $script:Root); $script:StartLog = @() }

    It 'übergibt die festen Argumente, Arbeitsordner und Zeitlimit (Start ist Attrappe)' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe; Argumente = $Argumente; TimeoutSek = $TimeoutSek; Arbeitsordner = $Arbeitsordner; Stream = $Stream }; @{ ok = $true; code = 0; ausgabe = [Text.Encoding]::UTF8.GetBytes('a,b'); fehlerAusgabe = (New-Object byte[] 0); zeitueberschreitung = $false; fehler = $null } }
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts -TimeoutSek 77
        $r.ok | Should Be $true
        $r.auftrag | Should Be 'autostarts'
        $r.code | Should Be 0
        $r.text | Should Be 'a,b'
        $r.nichtVertrauenswuerdig | Should Be $false
        $r.nichtEingerichtet | Should Be $false
        (@($r.Keys) -join ',') | Should Be 'ok,auftrag,code,text,fehler,dauerSek,nichtVertrauenswuerdig,nichtEingerichtet'
        $tools = Join-Path $script:Root 'tools'
        @($script:StartLog).Count | Should Be 1
        $l = $script:StartLog[0]
        $l.Exe | Should Be (Join-Path $tools 'autorunsc64.exe')
        ($l.Argumente -join ' ') | Should Be '-accepteula -nobanner -a * -c -s *'
        $l.TimeoutSek | Should Be 77
        $l.Arbeitsordner | Should Be $tools
        ($null -ne $l.Stream) | Should Be $true
    }
    It 'system32 und treiber nutzen sigcheck' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe; Argumente = $Argumente }; @{ ok = $true; code = 0; ausgabe = (New-Object byte[] 0); fehlerAusgabe = (New-Object byte[] 0); zeitueberschreitung = $false; fehler = $null } }
        $null = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag system32
        $null = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag treiber
        @($script:StartLog).Count | Should Be 2
        foreach ($l in $script:StartLog) { $l.Exe | Should Match 'sigcheck64\.exe$'; ($l.Argumente -contains '-v') | Should Be $false; ($l.Argumente -contains '-accepteula') | Should Be $true }
    }
    It 'unbekannter Auftrag: ok false, nichts gestartet' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe } }
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag 'virustotal'
        $r.ok | Should Be $false
        $r.fehler | Should Match 'Unbekannter'
        @($script:StartLog).Count | Should Be 0
    }
    It 'ohne Zustimmung: nichtEingerichtet, nichts gestartet' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe } }
        [void](Set-MorpheusSysZustimmung -DataRoot $script:Root -Akzeptiert $false)
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts
        $r.ok | Should Be $false
        $r.nichtEingerichtet | Should Be $true
        $r.nichtVertrauenswuerdig | Should Be $false
        $r.fehler | Should Not BeNullOrEmpty
        @($script:StartLog).Count | Should Be 0
    }
    It 'Datei fehlt: nichtEingerichtet' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe } }
        Remove-Item -LiteralPath (Join-Path $script:Root 'tools\autorunsc64.exe') -Force
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts
        $r.nichtEingerichtet | Should Be $true
        $r.fehler | Should Be 'Die Datei autorunsc64.exe fehlt.'
        @($script:StartLog).Count | Should Be 0
    }
    It 'Hash-Abweichung: nichtVertrauenswuerdig, nichts gestartet' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe } }
        [IO.File]::WriteAllText((Join-Path $script:Root 'tools\autorunsc64.exe'), 'MANIPULIERT')
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts
        $r.ok | Should Be $false
        $r.nichtVertrauenswuerdig | Should Be $true
        $r.nichtEingerichtet | Should Be $false
        $r.fehler | Should Match 'SHA256'
        @($script:StartLog).Count | Should Be 0
    }
    It 'Signatur ungültig / falscher Signierer / unsicherer Pfad: nichtVertrauenswuerdig' {
        Mock MorpheusSysStart { $script:StartLog += ,@{ Exe = $Exe } }
        $script:FSigStatus = 'NotSigned'
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts
        $r.nichtVertrauenswuerdig | Should Be $true
        $r.fehler | Should Match 'NotSigned'
        $script:FSigStatus = 'Valid'
        $script:FSubject = 'O=Evil Corp'
        (Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts).nichtVertrauenswuerdig | Should Be $true
        $script:FSubject = $script:GoodSubject
        $script:FUnsicherMuster = '\\tools$'
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts
        $r.nichtVertrauenswuerdig | Should Be $true
        $r.ok | Should Be $false
        @($script:StartLog).Count | Should Be 0
    }
    It 'Zeitüberschreitung: ok false, Fehlertext' {
        Mock MorpheusSysStart { @{ ok = $false; code = $null; ausgabe = (New-Object byte[] 0); fehlerAusgabe = (New-Object byte[] 0); zeitueberschreitung = $true; fehler = 'Zeitüberschreitung nach 1 Sekunden; der Prozess wurde beendet.' } }
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts -TimeoutSek 1
        $r.ok | Should Be $false
        $r.fehler | Should Match 'Zeitüberschreitung'
        $r.nichtVertrauenswuerdig | Should Be $false
    }
    It 'wirft nie, auch wenn der Start eine Ausnahme auslöst' {
        Mock MorpheusSysStart { throw 'kaputt' }
        $r = $null
        { $script:R = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts } | Should Not Throw
        $script:R.ok | Should Be $false
        $script:R.fehler | Should Match 'kaputt'
    }
}

Describe 'Invoke-MorpheusSysWerkzeug (echter Start)' {
    BeforeEach { Set-FakeSys; $script:Root = New-Sandbox; [void](Install-Fake -Root $script:Root) }

    It 'echter Lauf mit einer cmd.exe-Kopie als Attrappe: Ausgabe wird gelesen, Datei war gesperrt' {
        $tools = Join-Path $script:Root 'tools'
        $exe = Join-Path $tools 'autorunsc64.exe'
        Copy-Item -LiteralPath $script:CmdExe -Destination $exe -Force
        $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
        $j = [IO.File]::ReadAllText((Join-Path $tools 'werkzeuge.json')) | ConvertFrom-Json
        $script:FHerkunft = [pscustomobject]@{ CompanyName = 'Sysinternals - www.sysinternals.com'; ProductName = 'Sysinternals Autoruns' }
        $j.werkzeuge.autorunsc.sha256 = $hash
        [IO.File]::WriteAllText((Join-Path $tools 'werkzeuge.json'), ($j | ConvertTo-Json -Depth 6))
        $r = Invoke-MorpheusSysWerkzeug -DataRoot $script:Root -Auftrag autostarts -TimeoutSek 30
        $r.nichtVertrauenswuerdig | Should Be $false
        $r.ok | Should Be $true
        $r.text | Should Match 'Microsoft Corporation'
        # danach ist die Datei wieder frei
        $w = [IO.File]::Open($exe, 'Open', 'Write', 'ReadWrite'); $w.Dispose()
    }
}
