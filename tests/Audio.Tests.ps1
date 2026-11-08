#Requires -Version 5.1
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests fuer gui\lib\Audio.ps1: Auswertung mit gemockten CIM-/Registry-/WinRT-Daten, Syntax, nur lesend.
# Ausfuehren: Invoke-Pester tests\Audio.Tests.ps1

$script:Datei = Join-Path $PSScriptRoot '..\gui\lib\Audio.ps1'
. $script:Datei

function Ep($name, $ff = 1, $state = 1, $usb = $false, $fluss = 'Render', $guid = '{aaaa}') {
    [pscustomobject]@{ Fluss = $fluss; Guid = $guid; Name = $name; Adapter = 'Adapter'; FormFactor = $ff; State = $state; Usb = $usb }
}
function Std($wieder, $komm = $null, $auf = $null, $aufKomm = $null) {
    @{ Fehler = $null; Eintraege = @(
            [pscustomobject]@{ Rolle = 'Wiedergabe'; Endpunkt = $wieder },
            [pscustomobject]@{ Rolle = 'WiedergabeKomm'; Endpunkt = $komm },
            [pscustomobject]@{ Rolle = 'Aufnahme'; Endpunkt = $auf },
            [pscustomobject]@{ Rolle = 'AufnahmeKomm'; Endpunkt = $aufKomm }) }
}
function Dienste($state = 'Running', $mode = 'Auto', $state2 = 'Running', $mode2 = 'Auto') {
    @([pscustomobject]@{ Name = 'Audiosrv'; State = $state; StartMode = $mode }, [pscustomobject]@{ Name = 'AudioEndpointBuilder'; State = $state2; StartMode = $mode2 })
}

Describe 'Audio.ps1 Datei' {
    It 'hat BOM und gueltige Syntax' {
        $b = [IO.File]::ReadAllBytes($script:Datei)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
        $err = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Datei, [ref]$tok, [ref]$err)
        @($err).Count | Should Be 0
    }
    It 'liest nur: kein Add-Type, keine Schreibbefehle, keine Dienststeuerung' {
        $t = Get-Content -LiteralPath $script:Datei -Raw
        $t | Should Not Match 'Add-Type'
        $t | Should Not Match 'Set-ItemProperty|New-ItemProperty|Remove-Item|Set-Service|Start-Service|Stop-Service|Invoke-Expression|\biex\b'
    }
}

Describe 'Get-MorpheusAudioGuid' {
    It 'liest die GUID aus Wiedergabe- und Aufnahme-IDs' {
        Get-MorpheusAudioGuid '\\?\SWD#MMDEVAPI#{0.0.0.00000000}.{1f2e3d4c-0000-1111-2222-333344445555}#{e6327cad-dcec-4949-ae8a-991e976a79d2}' | Should Be '{1f2e3d4c-0000-1111-2222-333344445555}'
        Get-MorpheusAudioGuid '{0.0.1.00000000}.{ABCDEF01-0000-1111-2222-333344445555}' | Should Be '{ABCDEF01-0000-1111-2222-333344445555}'
    }
    It 'liefert bei unbekannter ID nichts' {
        Get-MorpheusAudioGuid 'quatsch' | Should BeNullOrEmpty
        Get-MorpheusAudioGuid '' | Should BeNullOrEmpty
    }
}

Describe 'Treiberfehler' {
    It 'gesunder PC: OK ohne Warnung' {
        $g = @([pscustomobject]@{ Name = 'A'; Code = 0; Present = $true }, [pscustomobject]@{ Name = 'B'; Code = 0; Present = $true })
        $b = Get-MorpheusAudioTreiberBefund -Geraete $g
        $b.Status | Should Be 'OK'
    }
    It 'Treiberfehler eines vorhandenen Geraets: WARN mit Name und Code' {
        $g = @([pscustomobject]@{ Name = 'Realtek Defekt'; Code = 10; Present = $true }, [pscustomobject]@{ Name = 'B'; Code = 0; Present = $true })
        $b = Get-MorpheusAudioTreiberBefund -Geraete $g
        $b.Status | Should Be 'WARN'
        $b.Value | Should Match 'Realtek Defekt'
        $b.Value | Should Match 'Code 10'
    }
    It 'nicht vorhandenes Geraet (Geist) mit Fehlercode wird ignoriert' {
        $g = @([pscustomobject]@{ Name = 'Geist'; Code = 45; Present = $false })
        (Get-MorpheusAudioTreiberBefund -Geraete $g).Status | Should Be 'OK'
    }
    It 'leere Liste ist OK' {
        (Get-MorpheusAudioTreiberBefund -Geraete @()).Status | Should Be 'OK'
    }
}

Describe 'Dienste' {
    It 'laufend und Auto: OK' {
        (Get-MorpheusAudioDienstBefund -Dienste (Dienste)).Status | Should Be 'OK'
    }
    It 'gestoppter Dienst: WARN' {
        $b = Get-MorpheusAudioDienstBefund -Dienste (Dienste 'Stopped')
        $b.Status | Should Be 'WARN'
        $b.Value | Should Match 'Audiosrv'
        $b.Value | Should Not Match 'AudioEndpointBuilder'
    }
    It 'Starttyp nicht Auto: WARN' {
        $b = Get-MorpheusAudioDienstBefund -Dienste (Dienste 'Running' 'Auto' 'Running' 'Manual')
        $b.Status | Should Be 'WARN'
        $b.Value | Should Match 'AudioEndpointBuilder'
    }
    It 'fehlender Dienst: WARN' {
        (Get-MorpheusAudioDienstBefund -Dienste @()).Status | Should Be 'WARN'
    }
}

Describe 'Standardgeraete' {
    It 'HDMI-Standardgeraet (FormFactor 9): INFO mit Hinweis und Link' {
        $b = Get-MorpheusAudioStandardBefund -Roh (Std (Ep 'NVIDIA Output' 9) (Ep 'NVIDIA Output' 9) (Ep 'Mikro' 4 1 $false 'Capture'))
        $b.Status | Should Be 'INFO'
        $b.Recommendation | Should Match 'HDMI'
        $b.Recommendation | Should Match 'ms-settings:sound'
        $b.Recommendation | Should Match 'LatencyMon'
        @($b.Zeilen).Count | Should Be 4
    }
    It 'normales Lautsprecher-Geraet: INFO ohne HDMI-Hinweis' {
        $b = Get-MorpheusAudioStandardBefund -Roh (Std (Ep 'Lautsprecher' 1))
        $b.Status | Should Be 'INFO'
        $b.Recommendation | Should Not Match 'HDMI'
        $b.Recommendation | Should Match 'ms-settings:sound'
    }
    It 'Standardgeraet nicht aktiv (ausgesteckt): Hinweis' {
        $b = Get-MorpheusAudioStandardBefund -Roh (Std (Ep 'Headset' 3 8))
        $b.Recommendation | Should Match 'Headset'
        $b.Recommendation | Should Match 'nicht verbunden'
    }
    It 'Geister-Endpunkt (State 4) wird nie gemeldet' {
        $b = Get-MorpheusAudioStandardBefund -Roh (Std (Ep 'Alter Monitor' 9 4))
        $b.Status | Should Be 'INFO'
        $b.Value | Should Not Match 'Alter Monitor'
        $b.Recommendation | Should Not Match 'HDMI'
    }
    It 'WinRT-Fehler: nicht ermittelbar, kein Abbruch' {
        $b = Get-MorpheusAudioStandardBefund -Roh @{ Fehler = 'kaputt'; Eintraege = @() }
        $b.Status | Should Be 'INFO'
        $b.Value | Should Match 'nicht ermittelbar'
        $b = Get-MorpheusAudioStandardBefund -Roh $null
        $b.Value | Should Match 'nicht ermittelbar'
    }
    It 'Get-MorpheusAudioStandard faengt WinRT-Ausnahmen ab' {
        Mock Get-MorpheusAudioWinRtId { throw 'WinRT nicht verfuegbar' }
        $r = Get-MorpheusAudioStandard
        $r.Fehler | Should Match 'WinRT'
        @($r.Eintraege).Count | Should Be 0
    }
    It 'Get-MorpheusAudioStandard loest IDs ueber die GUID auf' {
        Mock Get-MorpheusAudioWinRtId { '\\?\SWD#MMDEVAPI#{0.0.0.00000000}.{11111111-2222-3333-4444-555555555555}#{e6327cad}' }
        Mock Get-MorpheusAudioEndpunkt { Ep 'X' 1 1 $false $Fluss $Guid }
        $r = Get-MorpheusAudioStandard
        $r.Fehler | Should BeNullOrEmpty
        @($r.Eintraege).Count | Should Be 4
        $r.Eintraege[0].Endpunkt.Guid | Should Be '{11111111-2222-3333-4444-555555555555}'
    }
}

Describe 'USB-Energiesparen' {
    $an = { [pscustomobject]@{ AC = 1; DC = 1 } }
    $aus = { [pscustomobject]@{ AC = 0; DC = 0 } }
    It 'ohne aktives USB-Audio: OK, powercfg wird nicht aufgerufen' {
        $script:gerufen = $false
        $b = Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'Lautsprecher') -EnergieHolen { $script:gerufen = $true; [pscustomobject]@{ AC = 1; DC = 1 } }
        $b.Status | Should Be 'OK'
        $script:gerufen | Should Be $false
    }
    It 'inaktives (ausgestecktes) USB-Geraet zaehlt nicht' {
        (Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'USB Headset' 3 8 $true) -EnergieHolen $an).Status | Should Be 'OK'
    }
    It 'aktives USB-Audio und Energiesparen an: INFO' {
        $b = Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'USB Headset' 3 1 $true) -EnergieHolen $an
        $b.Status | Should Be 'INFO'
        $b.Value | Should Match 'Adapter'
    }
    It 'aktives USB-Audio und Energiesparen aus: OK' {
        (Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'USB Headset' 3 1 $true) -EnergieHolen $aus).Status | Should Be 'OK'
    }
    It 'powercfg nicht lesbar: INFO' {
        (Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'USB Headset' 3 1 $true) -EnergieHolen { $null }).Status | Should Be 'INFO'
    }
}

Describe 'Ducking' {
    It 'bildet alle Werte ab, immer INFO' {
        (Get-MorpheusAudioDuckingBefund -Wert $null).Value | Should Match '80 %'
        (Get-MorpheusAudioDuckingBefund -Wert 1).Value | Should Match '80 %'
        (Get-MorpheusAudioDuckingBefund -Wert 2).Value | Should Match '50 %'
        (Get-MorpheusAudioDuckingBefund -Wert 0).Value | Should Match 'stummgeschaltet'
        (Get-MorpheusAudioDuckingBefund -Wert 3).Value | Should Match 'unveraendert|unverändert'
        (Get-MorpheusAudioDuckingBefund -Wert 7).Status | Should Be 'INFO'
    }
    It 'formuliert als Vorliebe, nicht als Problem' {
        (Get-MorpheusAudioDuckingBefund -Wert 1).Recommendation | Should Match 'Vorliebe'
    }
}

Describe 'Gesunder PC' {
    It 'liefert keine Warnung' {
        $g = @([pscustomobject]@{ Name = 'A'; Code = 0; Present = $true })
        $alle = @(
            (Get-MorpheusAudioTreiberBefund -Geraete $g),
            (Get-MorpheusAudioDienstBefund -Dienste (Dienste)),
            (Get-MorpheusAudioStandardBefund -Roh (Std (Ep 'Lautsprecher'))),
            (Get-MorpheusAudioUsbBefund -Endpunkte @(Ep 'Lautsprecher') -EnergieHolen { $null }),
            (Get-MorpheusAudioDuckingBefund -Wert 3))
        @($alle | Where-Object { $_.Status -in 'WARN', 'CRIT' }).Count | Should Be 0
    }
}
