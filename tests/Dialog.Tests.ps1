#Requires -Version 5.1
$env:MORPHEUS_SPRACHE = 'de'
# Pester-3.4-Tests fuer gui\lib\Dialog.ps1 (Bestaetigungsdialog mit Wartezeit, Bremse und Verlauf, 2.10, #113) und
# Confirm-GuiElevated in Server.ps1. Die Logik (Wartezeit, Zaehler, Pause) ist rein und wird mit festen Zeitpunkten geprueft;
# das Fenster wird nur gebaut, nie angezeigt. Kein Dialog erscheint, nichts wird geaendert.
# Ausfuehren: Invoke-Pester tests\Dialog.Tests.ps1

. (Join-Path $PSScriptRoot '..\gui\lib\Server.ps1')

$script:DialogText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\Dialog.ps1'), [Text.Encoding]::UTF8)
$script:ServerText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\gui\lib\Server.ps1'), [Text.Encoding]::UTF8)
$script:FormsOk = $false
try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $script:FormsOk = $true } catch { }
$script:T0 = [datetime]'2026-11-15T12:00:00'

function script:NeuAbgelehnt {
    param([int]$Anzahl, $Z, [string]$Was = 'x')
    $letzte = 0
    for ($i = 0; $i -lt $Anzahl; $i++) { $letzte = Add-GuiDialogErgebnis -Zustand $Z -Ergebnis 'nein' -Was $Was -Jetzt $script:T0 }
    return $letzte
}

Describe 'Get-GuiDialogPauseDauer' {
    It 'verdoppelt je Stufe und deckelt bei 15 Minuten' {
        Get-GuiDialogPauseDauer -Stufe 0 | Should Be 60
        Get-GuiDialogPauseDauer -Stufe 1 | Should Be 120
        Get-GuiDialogPauseDauer -Stufe 2 | Should Be 240
        Get-GuiDialogPauseDauer -Stufe 3 | Should Be 480
        Get-GuiDialogPauseDauer -Stufe 4 | Should Be 900
        Get-GuiDialogPauseDauer -Stufe 40 | Should Be 900
    }
}

Describe 'Add-GuiDialogErgebnis (Bremse)' {
    It 'startet erst nach der dritten Ablehnung in Folge eine Pause von 60 s' {
        $z = New-GuiDialogZustand
        (Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'nein' -Was 'a' -Jetzt $script:T0) | Should Be 0
        (Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'zeit' -Was 'a' -Jetzt $script:T0) | Should Be 0
        Get-GuiDialogPauseRest -Zustand $z -Jetzt $script:T0 | Should Be 0
        (Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'nein' -Was 'a' -Jetzt $script:T0) | Should Be 60
        Get-GuiDialogPauseRest -Zustand $z -Jetzt $script:T0 | Should Be 60
        Get-GuiDialogPauseRest -Zustand $z -Jetzt $script:T0.AddSeconds(59.5) | Should Be 1
        Get-GuiDialogPauseRest -Zustand $z -Jetzt $script:T0.AddSeconds(60) | Should Be 0
    }
    It 'Ja setzt Zaehler und Stufe zurueck' {
        $z = New-GuiDialogZustand
        [void](NeuAbgelehnt 2 $z)
        (Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'ja' -Was 'a' -Jetzt $script:T0) | Should Be 0
        $z.Ablehnungen | Should Be 0
        (NeuAbgelehnt 2 $z) | Should Be 0
        (NeuAbgelehnt 1 $z) | Should Be 60
        # Nach der ersten Pause: Stufe 1, Ja setzt auch die Stufe zurueck
        $z.Stufe | Should Be 1
        [void](Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'ja' -Was 'a' -Jetzt $script:T0)
        $z.Stufe | Should Be 0
    }
    It 'verlaengert die Pause bei erneuten Ablehnungen (60, 120, 240 s)' {
        $z = New-GuiDialogZustand
        (NeuAbgelehnt 3 $z) | Should Be 60
        (NeuAbgelehnt 3 $z) | Should Be 120
        (NeuAbgelehnt 3 $z) | Should Be 240
    }
    It 'zaehlt Anfragen in der Pause nicht als Ablehnung und fasst sie zusammen' {
        $z = New-GuiDialogZustand
        [void](NeuAbgelehnt 3 $z)
        for ($i = 0; $i -lt 50; $i++) { (Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'pause' -Was 'b' -Jetzt $script:T0) | Should Be 0 }
        $z.Ablehnungen | Should Be 0
        $z.Verlauf.Count | Should Be 4
        $z.Verlauf[3].ergebnis | Should Be 'pause'
        $z.Verlauf[3].anzahl | Should Be 50
    }
    It 'behaelt hoechstens 20 Verlaufseintraege' {
        $z = New-GuiDialogZustand
        for ($i = 0; $i -lt 30; $i++) { [void](Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'ja' -Was "e$i" -Jetzt $script:T0) }
        $z.Verlauf.Count | Should Be 20
        $z.Verlauf[0].was | Should Be 'e10'
    }
    It 'Get-GuiDialogVerlauf liefert neueste zuerst' {
        $z = New-GuiDialogZustand
        [void](Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'ja' -Was 'alt' -Jetzt $script:T0)
        [void](Add-GuiDialogErgebnis -Zustand $z -Ergebnis 'nein' -Was 'neu' -Jetzt $script:T0.AddSeconds(5))
        $v = @(Get-GuiDialogVerlauf $z)
        $v.Count | Should Be 2
        $v[0].was | Should Be 'neu'
        $v[0].ergebnis | Should Be 'nein'
        $v[1].was | Should Be 'alt'
        @(Get-GuiDialogVerlauf $null).Count | Should Be 0
    }
}

Describe 'Get-GuiDialogAnzeige (Wartezeit)' {
    It 'sperrt Ja in den ersten 2 s und zaehlt herunter' {
        $a = Get-GuiDialogAnzeige -Verstrichen 0
        $a.JaFrei | Should Be $false
        $a.JaRest | Should Be 2
        (Get-GuiDialogAnzeige -Verstrichen 0.4).JaRest | Should Be 2
        (Get-GuiDialogAnzeige -Verstrichen 1.2).JaRest | Should Be 1
        (Get-GuiDialogAnzeige -Verstrichen 1.9).JaFrei | Should Be $false
        $b = Get-GuiDialogAnzeige -Verstrichen 2
        $b.JaFrei | Should Be $true
        $b.JaRest | Should Be 0
    }
    It 'laeuft nach 120 s ab' {
        (Get-GuiDialogAnzeige -Verstrichen 119.9).Abgelaufen | Should Be $false
        (Get-GuiDialogAnzeige -Verstrichen 120).Abgelaufen | Should Be $true
        (Get-GuiDialogAnzeige -Verstrichen 5).TimeoutRest | Should Be 115
    }
}

Describe 'Invoke-GuiBestaetigung' {
    BeforeEach {
        Mock Write-GuiLog { }
        $script:Gezeigt = 0
        $script:AntwortFolge = New-Object System.Collections.Queue
    }
    It 'gibt Ok nur bei Ja' {
        $z = New-GuiDialogZustand
        $r = Invoke-GuiBestaetigung -Zustand $z -Text "Frage?`n`n• Titel" -Anzeige { param($t) 'ja' }
        $r.Ok | Should Be $true
        $r.Ergebnis | Should Be 'ja'
        $z.Verlauf[0].was | Should Match 'Frage\? · • Titel'
        foreach ($erg in 'nein', 'zeit', 'unsinn') {
            $r = Invoke-GuiBestaetigung -Zustand (New-GuiDialogZustand) -Text 'F' -Anzeige ([scriptblock]::Create("param(`$t) '$erg'"))
            $r.Ok | Should Be $false
        }
    }
    It 'wertet einen Fehler im Dialog als Ablehnung (fail-closed), zaehlt sie und loggt' {
        $z = New-GuiDialogZustand
        $r = Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) throw 'kein Desktop' }
        $r.Ok | Should Be $false
        $r.Ergebnis | Should Be 'nein'
        $z.Ablehnungen | Should Be 1
        Assert-MockCalled Write-GuiLog -ParameterFilter { $Text -match 'Dialog-Fehler.*kein Desktop' } -Times 1
        # Mehrere Ausgaben statt einer Antwort: nie ein "ja"
        (Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) 'ja'; 'ja' }).Ok | Should Be $false
    }
    It 'zeigt in der Pause keinen Dialog und meldet pause' {
        $z = New-GuiDialogZustand
        $nein = { param($t) $script:Gezeigt++; 'nein' }
        for ($i = 0; $i -lt 3; $i++) { [void](Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige $nein) }
        $script:Gezeigt | Should Be 3
        $r = Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige $nein
        $r.Ergebnis | Should Be 'pause'
        $r.Ok | Should Be $false
        ($r.PauseRest -gt 0) | Should Be $true
        $script:Gezeigt | Should Be 3
    }
    It 'schreibt Ereignisse und Bremse ins gui.log' {
        $z = New-GuiDialogZustand
        for ($i = 0; $i -lt 3; $i++) { [void](Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) 'nein' }) }
        [void](Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) 'nein' })
        Assert-MockCalled Write-GuiLog -ParameterFilter { $Text -match '^Dialog: nein \(Ablehnungen in Folge: 3\)' } -Times 0
        Assert-MockCalled Write-GuiLog -ParameterFilter { $Text -match '^Dialog: nein \(Ablehnungen in Folge: 2\)' } -Times 1
        Assert-MockCalled Write-GuiLog -ParameterFilter { $Text -match 'Dialog-Bremse: 3 Ablehnungen in Folge, Pause 60 s' } -Times 1
        Assert-MockCalled Write-GuiLog -ParameterFilter { $Text -match 'Dialog-Bremse: Anfrage ohne Dialog abgelehnt, Pause noch' } -Times 1
    }
    It 'nach der Pause wird wieder gefragt' {
        $z = New-GuiDialogZustand
        for ($i = 0; $i -lt 3; $i++) { [void](Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) 'nein' }) }
        $z.PauseBis = (Get-Date).AddSeconds(-1)
        $r = Invoke-GuiBestaetigung -Zustand $z -Text 'F' -Anzeige { param($t) 'ja' }
        $r.Ok | Should Be $true
    }
}

Describe 'Confirm-GuiElevated' {
    BeforeEach { Mock Write-GuiLog { }; $script:Gui = @{ Dialog = (New-GuiDialogZustand) } }
    It 'wirft in der Pause 429 mit Text und Restzeit, ohne Dialog' {
        $script:Gui.Dialog.PauseBis = (Get-Date).AddSeconds(30)
        $status = $null; $msg = $null
        try { [void](Confirm-GuiElevated 'Text') } catch { $status = $_.Exception.Data['status']; $msg = $_.Exception.Message }
        $status | Should Be 429
        $msg | Should Match '\d+ s'
    }
    It 'ruft keinen MessageBox-Dialog mehr auf' {
        $script:ServerText | Should Not Match 'MessageBoxW'
        $script:DialogText | Should Not Match 'DllImport|MemberDefinition|Add-Type -Namespace'
    }
}

Describe 'Dialogfenster (nur gebaut, nicht angezeigt)' {
    BeforeEach { if ($script:FormsOk) { $script:Ui = New-GuiBestaetigungsForm -Text "A`nB" -Titel 'Titel' } }
    AfterEach { if ($script:Ui) { $script:Ui.Form.Dispose(); $script:Ui = $null } }
    It 'Enter und Esc waehlen Nein, Nein ist vorbelegt, Ja ist anfangs gesperrt' -Skip:(-not $script:FormsOk) {
        $script:Ui.Form.AcceptButton | Should Be $script:Ui.Nein
        $script:Ui.Form.CancelButton | Should Be $script:Ui.Nein
        $script:Ui.Form.ActiveControl | Should Be $script:Ui.Nein
        $script:Ui.Ja.Enabled | Should Be $false
        $script:Ui.Ja.Text | Should Be 'Ja (2)'
        $script:Ui.Form.TopMost | Should Be $true
    }
    It 'kein Tastenkuerzel (&) auf den Knoepfen, Ja nur ueber DialogResult Yes' -Skip:(-not $script:FormsOk) {
        $script:Ui.Ja.UseMnemonic | Should Be $false
        $script:Ui.Ja.TabStop | Should Be $false
        $script:Ui.Nein.UseMnemonic | Should Be $false
        $script:Ui.Ja.Text | Should Not Match '&'
        $script:Ui.Nein.Text | Should Not Match '&'
        [string]$script:Ui.Ja.DialogResult | Should Be 'Yes'
        [string]$script:Ui.Nein.DialogResult | Should Be 'No'
    }
    It 'Update schaltet Ja nach der Wartezeit frei und meldet den Ablauf' -Skip:(-not $script:FormsOk) {
        $a = Update-GuiBestaetigungsForm -Ui $script:Ui -Verstrichen 0.5
        $a.Abgelaufen | Should Be $false
        $script:Ui.Ja.Enabled | Should Be $false
        $script:Ui.Ja.Text | Should Be 'Ja (2)'
        [void](Update-GuiBestaetigungsForm -Ui $script:Ui -Verstrichen 1.5)
        $script:Ui.Ja.Text | Should Be 'Ja (1)'
        [void](Update-GuiBestaetigungsForm -Ui $script:Ui -Verstrichen 2.1)
        $script:Ui.Ja.Enabled | Should Be $true
        $script:Ui.Ja.Text | Should Be 'Ja'
        (Update-GuiBestaetigungsForm -Ui $script:Ui -Verstrichen 121).Abgelaufen | Should Be $true
    }
    # Sicherheitspruefung 2.10, Z1: Pfeiltasten wechseln den Fokus unabhaengig von TabStop. Das Fenster wird dafuer
    # unsichtbar (Opacity 0, ausserhalb des Bildschirms) geoeffnet, weil nur sichtbare Knoepfe den Fokus annehmen.
    It 'Pfeiltasten und Tab erreichen Ja nicht, auch nach der Wartezeit' -Skip:(-not $script:FormsOk) {
        $f = $script:Ui.Form
        $f.Opacity = 0; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
        $f.Location = New-Object System.Drawing.Point -5000, -5000
        $f.Show()
        try {
            [void](Update-GuiBestaetigungsForm -Ui $script:Ui -Verstrichen 5)
            $script:Ui.Ja.Enabled | Should Be $true
            $m = [System.Windows.Forms.Form].GetMethod('ProcessDialogKey', [Reflection.BindingFlags]'Instance,NonPublic')
            foreach ($k in 'Left', 'Right', 'Up', 'Down', 'Tab') {
                foreach ($start in $script:Ui.Nein, $f.Controls[0]) {
                    [void]$start.Select()
                    [void]$m.Invoke($f, @([System.Windows.Forms.Keys]$k))
                    ($f.ActiveControl -eq $script:Ui.Ja) | Should Be $false
                    $script:Ui.Ja.Focused | Should Be $false
                }
            }
        }
        finally { $f.Hide() }
    }
}

Describe 'Einbindung' {
    It 'Server.ps1 laedt Dialog.ps1, legt den Zustand an und liefert dialoge in /api/session' {
        $script:ServerText | Should Match "Join-Path \`$PSScriptRoot 'Dialog\.ps1'"
        $script:ServerText | Should Match 'Dialog = \(New-GuiDialogZustand\)'
        $script:ServerText | Should Match 'dialoge = @\(Get-GuiDialogVerlauf \$g\.Dialog\)'
    }
    It 'neue Textschluessel in beiden Sprachen' {
        foreach ($sp in 'de', 'en') {
            $t = Import-PowerShellDataFile (Join-Path $PSScriptRoot "..\lang\$sp\server.psd1")
            foreach ($k in 'ja', 'nein', 'jaWarten', 'wartehinweis', 'zeitHinweis', 'pause') { $t.ContainsKey("server.dialog.$k") | Should Be $true }
            $g = Import-PowerShellDataFile (Join-Path $PSScriptRoot "..\lang\$sp\gui.psd1")
            foreach ($k in 'dialoge', 'dialogeSub', 'dlgKeine', 'dlg.ja', 'dlg.nein', 'dlg.zeit', 'dlg.pause') { $g.ContainsKey("gui.jr.$k") | Should Be $true }
        }
    }
}
