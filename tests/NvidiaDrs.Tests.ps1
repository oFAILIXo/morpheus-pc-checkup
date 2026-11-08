#Requires -Version 5.1
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests fuer gui\lib\NvidiaDrs.ps1: Auswertung und Zeilenparser ohne NVIDIA-Hardware, Signaturregeln, statische Pruefung.
# Ausfuehren: Invoke-Pester tests\NvidiaDrs.Tests.ps1

$script:Datei = Join-Path $PSScriptRoot '..\gui\lib\NvidiaDrs.ps1'
. $script:Datei

function Roh {
    param([hashtable]$Werte = @{}, [int]$Status = 0)
    # Werte: Name -> uint32; fehlt der Name, ist die Einstellung nicht gesetzt (-160)
    foreach ($n in $script:MorpheusNvidiaIds.Keys) {
        if ($Werte.ContainsKey($n)) { [pscustomobject]@{ Id = $script:MorpheusNvidiaIds[$n]; Status = $Status; Typ = '0'; Ort = '2'; Vordefiniert = '0'; Wert = [uint32]$Werte[$n] } }
        else { [pscustomobject]@{ Id = $script:MorpheusNvidiaIds[$n]; Status = -160; Typ = ''; Ort = ''; Vordefiniert = ''; Wert = $null } }
    }
}

Describe 'NvidiaDrs.ps1 Datei' {
    It 'hat BOM und gueltige Syntax' {
        $b = [IO.File]::ReadAllBytes($script:Datei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
        $err = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Datei, [ref]$tok, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'schreibt nie: kein DRS_SetSetting, SaveSettings, CreateProfile oder DeleteProfile' {
        $t = Get-Content -LiteralPath $script:Datei -Raw
        $t | Should Not Match 'SetSetting'
        $t | Should Not Match 'CreateProfile|DeleteProfile'
        $t | Should Not Match 'SaveSettings'
    }
    It 'laedt die DLL nur mit LOAD_LIBRARY_SEARCH_SYSTEM32 und vollem System32-Pfad' {
        $t = Get-Content -LiteralPath $script:Datei -Raw
        $t | Should Match 'LoadLibraryExW\(dllPath, IntPtr.Zero, 0x800\)'
        (Get-Content -LiteralPath $script:Datei -Raw) | Should Match 'SystemDirectory'
    }
    It 'verwendet die geprueften Setting-IDs aus NvApiDriverSettings.h' {
        $script:MorpheusNvidiaIds.Shadercache | Should Be ([uint32]0x00198FFF)
        $script:MorpheusNvidiaIds.ShadercacheGroesse | Should Be ([uint32]0x00AC8497)
        $script:MorpheusNvidiaIds.Energie | Should Be ([uint32]0x1057EB71)
        $script:MorpheusNvidiaIds.VSync | Should Be ([uint32]0x00A879CF)
        $script:MorpheusNvidiaIds.MaxBildrate | Should Be ([uint32]0x10835002)
        $script:MorpheusNvidiaIds.GSync | Should Be ([uint32]0x1194F158)
    }
}

Describe 'Test-MorpheusNvapiHersteller' {
    It 'akzeptiert WHQL (Microsoft) und NVIDIA mit Hersteller NVIDIA' {
        Test-MorpheusNvapiHersteller 'Valid' 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation' 'NVIDIA Corporation' | Should BeNullOrEmpty
        Test-MorpheusNvapiHersteller 'Valid' 'CN=NVIDIA Corporation, O=NVIDIA Corporation' 'NVIDIA Corporation' | Should BeNullOrEmpty
    }
    It 'lehnt ungueltige Signatur, fremden Herausgeber und fremden Hersteller ab' {
        Test-MorpheusNvapiHersteller 'HashMismatch' 'CN=NVIDIA Corporation, O=x' 'NVIDIA Corporation' | Should Not BeNullOrEmpty
        Test-MorpheusNvapiHersteller 'Valid' 'CN=Evil Corp, O=x' 'NVIDIA Corporation' | Should Not BeNullOrEmpty
        Test-MorpheusNvapiHersteller 'Valid' 'CN=NVIDIA Corporation, O=x' 'Evil' | Should Not BeNullOrEmpty
        Test-MorpheusNvapiHersteller 'Valid' 'CN=Fake NVIDIA Corporation, O=x' 'NVIDIA' | Should Not BeNullOrEmpty
    }
}

Describe 'ConvertFrom-MorpheusNvapiZeile' {
    It 'liest eine gesetzte DWORD-Einstellung' {
        $o = ConvertFrom-MorpheusNvapiZeile '0x00A879CF|0|0|2|0|1620202130'
        $o.Id | Should Be ([uint32]0x00A879CF)
        $o.Status | Should Be 0
        $o.Wert | Should Be ([uint32]1620202130)
        $o.Wert | Should Be ([uint32]0x60925292)
    }
    It 'liest NOT_FOUND ohne Wert' {
        $o = ConvertFrom-MorpheusNvapiZeile '0x00198FFF|-160||||'
        $o.Status | Should Be -160
        $o.Wert | Should BeNullOrEmpty
    }
    It 'gibt bei kaputten Zeilen $null zurueck' {
        ConvertFrom-MorpheusNvapiZeile 'quatsch' | Should BeNullOrEmpty
        ConvertFrom-MorpheusNvapiZeile 'xx|1|2|3|4|5' | Should BeNullOrEmpty
    }
}

Describe 'Get-MorpheusNvidiaBefund' {
    It 'Alles Standard: OK, sechs Zeilen' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh)
        $b.Status | Should Be 'OK'
        $b.Zeilen.Count | Should Be 6
        $b.Gelesen | Should Be 6
        @($b.Hinweise).Count | Should Be 0
    }
    It 'Beispiel: V-Sync "Anwendung entscheidet" ist OK' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh @{ VSync = 0x60925292 })
        $b.Status | Should Be 'OK'
        ($b.Zeilen | Where-Object Einstellung -Match 'V-Sync').Wert | Should Be 'Anwendung entscheidet'
    }
    It 'Shader-Cache aus ist eine Warnung' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh @{ Shadercache = 0 })
        $b.Status | Should Be 'WARN'
        @($b.Hinweise).Count | Should Be 1
    }
    It 'Shader-Cache-Groesse: 0 Warnung, 512 MB Tipp, 16384 MB und unbegrenzt OK' {
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ ShadercacheGroesse = 0 })).Status | Should Be 'WARN'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ ShadercacheGroesse = 512 })).Status | Should Be 'INFO'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ ShadercacheGroesse = 16384 })).Status | Should Be 'OK'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ ShadercacheGroesse = 4294967295 })).Status | Should Be 'OK'
    }
    It 'Energieverwaltung: nur "Maximale Leistung" ist ein Tipp' {
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ Energie = 1 })).Status | Should Be 'INFO'
        foreach ($w in 0, 2, 3, 4, 5) { (Get-MorpheusNvidiaBefund -Roh @(Roh @{ Energie = $w })).Status | Should Be 'OK' }
    }
    It 'V-Sync: jede Erzwingung ist ein Tipp' {
        foreach ($w in 0x08416747, 0x47814940, 0x32610244, 0x71271021, 0x13245256, 0x18888888) {
            (Get-MorpheusNvidiaBefund -Roh @(Roh @{ VSync = $w })).Status | Should Be 'INFO'
        }
    }
    It 'Max. Bildrate: Begrenzung ist ein Tipp mit der Zahl im Hinweis' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh @{ MaxBildrate = 144 })
        $b.Status | Should Be 'INFO'
        $b.Hinweise[0] | Should Match '144'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ MaxBildrate = 0 })).Status | Should Be 'OK'
    }
    It 'G-SYNC: aus ist ein Tipp, Vollbild und Fenster sind OK' {
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ GSync = 0 })).Status | Should Be 'INFO'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ GSync = 1 })).Status | Should Be 'OK'
        (Get-MorpheusNvidiaBefund -Roh @(Roh @{ GSync = 2 })).Status | Should Be 'OK'
    }
    It 'schlechtester Status gewinnt' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh @{ Shadercache = 0; VSync = 0x47814940 })
        $b.Status | Should Be 'WARN'
        @($b.Hinweise).Count | Should Be 2
    }
    It 'unlesbare Einstellungen zaehlen nicht als gelesen und werden nicht bewertet' {
        $b = Get-MorpheusNvidiaBefund -Roh @()
        $b.Gelesen | Should Be 0
        $b.Status | Should Be 'OK'
        $b.Zeilen.Count | Should Be 6
        $r = @(Roh) | ForEach-Object { $_.Status = -5; $_.Wert = $null; $_ }
        (Get-MorpheusNvidiaBefund -Roh $r).Gelesen | Should Be 0
    }
    It 'unbekannter Wert wird als Hex angezeigt, nicht bewertet' {
        $b = Get-MorpheusNvidiaBefund -Roh @(Roh @{ VSync = 2882400001 })
        $b.Status | Should Be 'OK'
        ($b.Zeilen | Where-Object Einstellung -Match 'V-Sync').Wert | Should Be '0xABCDEF01'
    }
}

Describe 'Sprachdateien' {
    It 'alle scan.nvidia.*-Schluessel stehen in de und en' {
        $root = Join-Path $PSScriptRoot '..'
        $de = Import-PowerShellDataFile (Join-Path $root 'lang\de\leistung.psd1')
        $en = Import-PowerShellDataFile (Join-Path $root 'lang\en\leistung.psd1')
        $k = @($de.Keys | Where-Object { $_ -like 'scan.nvidia.*' -or $_ -like 'scan.gaming.nvidia*' })
        $k.Count | Should BeGreaterThan 40
        foreach ($x in $k) { $en.ContainsKey($x) | Should Be $true }
        # alle im Code verwendeten Schluessel existieren
        $code = Get-Content -LiteralPath $script:Datei -Raw
        foreach ($m in [regex]::Matches($code, "T '(scan\.nvidia\.[A-Za-z0-9.]+)'")) { $de.ContainsKey($m.Groups[1].Value) | Should Be $true }
        foreach ($n in $script:MorpheusNvidiaIds.Keys) { $de.ContainsKey('scan.nvidia.n.' + $n) | Should Be $true }
    }
}
