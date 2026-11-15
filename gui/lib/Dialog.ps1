#Requires -Version 5.1
<#
.SYNOPSIS
    Bestätigungsdialog für ändernde Aktionen: eigenes Fenster mit Wartezeit, Bremse nach Ablehnungen und Verlauf (v2.10, #113).

.DESCRIPTION
    Wird per Dot-Source von Server.ps1 geladen. Vertrag: docs/gui-architektur.md Abschnitt 22.
    Bedrohung: Wer das GUI-Token hat (z. B. ein Schadprogramm mit Benutzerrechten), kann Bestätigungsdialoge beliebig oft
    auslösen, auch in einem Moment, in dem der Nutzer gerade tippt oder klickt. Der alte MessageBoxW-Dialog hatte keine Wartezeit,
    und die Tasten J/Y/Enter konnten „Ja“ auslösen. Windows (UIPI) verhindert weiterhin, dass ein Programm ohne Adminrechte
    in das Fenster dieses Admin-Prozesses klickt oder tippt.
    - Ja-Knopf: in den ersten Sekunden gesperrt (Zähler im Knopf). Kein Kürzel: Enter und Esc wählen „Nein“, kein &-Kürzel,
      Schließen und Zeitüberschreitung gelten als Ablehnung. Fenster immer im Vordergrund (TopMost).
    - Der Dialog läuft im Server-Prozess und hält die Hauptschleife an: Während er offen ist, kann kein Token-Aufruf ihn schließen
      oder durch einen zweiten Dialog ersetzen.
    - Bremse: Nach 3 Ablehnungen (Nein, Schließen, Zeitüberschreitung) in Folge fragt der Server eine Pause lang gar nicht mehr
      (60 s, dann 120 s, 240 s … höchstens 15 min); Anfragen in der Pause werden ohne Dialog abgelehnt (HTTP 429). „Ja“ setzt zurück.
    - Verlauf: die letzten 20 Dialoge (Zeit, Ergebnis, erste Zeilen des Textes) für die GUI (/api/session, Feld dialoge) und gui.log.
    Nicht verhindert: ein Benutzer, der absichtlich „Ja“ klickt, nachdem ein Schadprogramm eine harmlos wirkende Anfrage gestellt hat.
    Bewusst kein Add-Type mit Kompilieren (DLL in %TEMP%): nur System.Windows.Forms aus dem GAC.
#>

$script:GuiDialogWartezeit = 2       # Sekunden, in denen „Ja“ gesperrt ist
$script:GuiDialogTimeout = 120       # Sekunden bis zur automatischen Ablehnung
$script:GuiDialogBisPause = 3        # Ablehnungen in Folge bis zur Pause
$script:GuiDialogPauseBasis = 60     # erste Pause in Sekunden, danach verdoppelt
$script:GuiDialogPauseMax = 900
$script:GuiDialogVerlaufMax = 20

function New-GuiDialogZustand {
    @{ Ablehnungen = 0; Stufe = 0; PauseBis = [datetime]::MinValue; Verlauf = (New-Object System.Collections.Generic.List[object]) }
}

function Get-GuiDialogPauseRest {
    # Verbleibende Pause in Sekunden (aufgerundet), 0 = es darf gefragt werden.
    param([Parameter(Mandatory)]$Zustand, [Parameter(Mandatory)][datetime]$Jetzt)
    $r = ($Zustand.PauseBis - $Jetzt).TotalSeconds
    if ($r -gt 0) { return [int][math]::Ceiling($r) }
    return 0
}

function Get-GuiDialogPauseDauer {
    # Pause in Sekunden für die Stufe (0 = 60 s, 1 = 120 s, … höchstens $GuiDialogPauseMax).
    param([int]$Stufe)
    $d = [double]$script:GuiDialogPauseBasis
    for ($i = 0; $i -lt $Stufe; $i++) { $d = $d * 2; if ($d -ge $script:GuiDialogPauseMax) { return [int]$script:GuiDialogPauseMax } }
    return [int][math]::Min($d, $script:GuiDialogPauseMax)
}

function Add-GuiDialogErgebnis {
    # Trägt ein Ergebnis ein ('ja', 'nein', 'zeit', 'pause') und liefert die neu gestartete Pause in Sekunden (sonst 0).
    # 'pause' = Anfrage ohne Dialog abgelehnt; mehrere in Folge werden zu einem Eintrag mit Anzahl zusammengefasst,
    # damit ein Programm, das in der Pause weiter anfragt, den Verlauf nicht mit Pausen-Einträgen füllt.
    param([Parameter(Mandatory)]$Zustand, [Parameter(Mandatory)][ValidateSet('ja', 'nein', 'zeit', 'pause')][string]$Ergebnis,
        [string]$Was, [Parameter(Mandatory)][datetime]$Jetzt)
    $v = $Zustand.Verlauf
    $letzter = $null
    if ($v.Count -gt 0) { $letzter = $v[$v.Count - 1] }
    if (($Ergebnis -ceq 'pause') -and $letzter -and ($letzter.ergebnis -ceq 'pause')) {
        $letzter.anzahl = [int]$letzter.anzahl + 1
        $letzter.zeit = $Jetzt.ToString('yyyy-MM-ddTHH:mm:ss')
    } else {
        $v.Add([ordered]@{ zeit = $Jetzt.ToString('yyyy-MM-ddTHH:mm:ss'); ergebnis = $Ergebnis; was = $Was; anzahl = 1 })
        while ($v.Count -gt $script:GuiDialogVerlaufMax) { $v.RemoveAt(0) }
    }
    if ($Ergebnis -ceq 'ja') { $Zustand.Ablehnungen = 0; $Zustand.Stufe = 0; return 0 }
    if ($Ergebnis -ceq 'pause') { return 0 }
    $Zustand.Ablehnungen = [int]$Zustand.Ablehnungen + 1
    if ($Zustand.Ablehnungen -ge $script:GuiDialogBisPause) {
        $sek = Get-GuiDialogPauseDauer -Stufe $Zustand.Stufe
        $Zustand.PauseBis = $Jetzt.AddSeconds($sek)
        $Zustand.Stufe = [int]$Zustand.Stufe + 1
        $Zustand.Ablehnungen = 0
        return $sek
    }
    return 0
}

function Get-GuiDialogAnzeige {
    # Zustand des Fensters nach $Verstrichen Sekunden (rein, ohne Oberfläche): JaFrei, JaRest (Sekunden bis „Ja“ frei),
    # Abgelaufen, TimeoutRest.
    param([double]$Verstrichen, [int]$Wartezeit = $script:GuiDialogWartezeit, [int]$Timeout = $script:GuiDialogTimeout)
    $rest = [int][math]::Ceiling($Wartezeit - $Verstrichen)
    if ($rest -lt 0) { $rest = 0 }
    $tr = [int][math]::Ceiling($Timeout - $Verstrichen)
    if ($tr -lt 0) { $tr = 0 }
    [pscustomobject]@{ JaFrei = ($rest -eq 0); JaRest = $rest; Abgelaufen = ($Verstrichen -ge $Timeout); TimeoutRest = $tr }
}

function Get-GuiDialogKurztext {
    # Erste nicht leere Zeilen des Dialogtextes für den Verlauf (ohne Steuer- und Bidi-Zeichen, gekürzt).
    param([AllowNull()][string]$Text, [int]$Zeilen = 2, [int]$Max = 160)
    $z = @(([string]$Text -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -First $Zeilen)
    return (Format-GuiDialogWert ($z -join ' · ') $Max)
}

function New-GuiBestaetigungsForm {
    # Baut das Fenster (zeigt es nicht). Liefert Form, Ja, Nein, Hinweis. Getrennt vom Anzeigen, damit Tests es prüfen können.
    param([string]$Text, [string]$Titel)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Titel
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.TopMost = $true; $f.ShowInTaskbar = $true
    $f.ClientSize = New-Object System.Drawing.Size 560, 390
    $f.Font = New-Object System.Drawing.Font 'Segoe UI', 9
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.TabStop = $false
    $tb.BackColor = [System.Drawing.SystemColors]::Window
    $tb.Location = New-Object System.Drawing.Point 12, 12
    $tb.Size = New-Object System.Drawing.Size 536, 272
    $tb.Text = (([string]$Text) -replace "\r?\n", "`r`n")
    $f.Controls.Add($tb)
    $hint = New-Object System.Windows.Forms.Label
    $hint.UseMnemonic = $false
    $hint.Location = New-Object System.Drawing.Point 12, 292
    $hint.Size = New-Object System.Drawing.Size 536, 44
    $f.Controls.Add($hint)
    $ja = New-Object System.Windows.Forms.Button
    $ja.UseMnemonic = $false
    $ja.Text = (T 'server.dialog.jaWarten' $script:GuiDialogWartezeit)
    $ja.Enabled = $false
    # Per Tastatur nicht erreichbar (kein Tab + Leertaste, das beim Tippen im falschen Fenster zufällig vorkommen kann): nur Mausklick
    $ja.TabStop = $false
    $ja.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $ja.Location = New-Object System.Drawing.Point 0, 0
    $ja.Size = New-Object System.Drawing.Size 100, 28
    # Eigenes Panel: Pfeiltasten wechseln den Fokus unabhängig von TabStop, aber nur unter Geschwistern im selben
    # Container (ContainerControl.ProcessArrowKey). Ohne Panel erreichte Pfeil links/oben „Ja“ (Sicherheitsprüfung 2.10, Z1).
    $jaRahmen = New-Object System.Windows.Forms.Panel
    $jaRahmen.TabStop = $false
    $jaRahmen.Location = New-Object System.Drawing.Point 336, 350
    $jaRahmen.Size = $ja.Size
    $jaRahmen.Controls.Add($ja)
    $f.Controls.Add($jaRahmen)
    $nein = New-Object System.Windows.Forms.Button
    $nein.UseMnemonic = $false
    $nein.Text = (T 'server.dialog.nein')
    $nein.DialogResult = [System.Windows.Forms.DialogResult]::No
    $nein.Location = New-Object System.Drawing.Point 448, 350
    $nein.Size = New-Object System.Drawing.Size 100, 28
    $f.Controls.Add($nein)
    # Enter und Esc wählen „Nein“; „Ja“ gibt es nur per Mausklick (weder Kürzel noch Tab-Reihenfolge)
    $f.AcceptButton = $nein
    $f.CancelButton = $nein
    $f.ActiveControl = $nein
    [pscustomobject]@{ Form = $f; Ja = $ja; Nein = $nein; Hinweis = $hint }
}

function Update-GuiBestaetigungsForm {
    # Überträgt Get-GuiDialogAnzeige auf die Knöpfe. Liefert die Anzeige (Abgelaufen = true: Fenster schließen).
    param($Ui, [double]$Verstrichen)
    $a = Get-GuiDialogAnzeige -Verstrichen $Verstrichen
    if ($a.JaFrei) {
        $Ui.Ja.Text = (T 'server.dialog.ja')
        $Ui.Hinweis.Text = (T 'server.dialog.zeitHinweis' $a.TimeoutRest)
        $Ui.Ja.Enabled = $true
    } else {
        $Ui.Ja.Enabled = $false
        $Ui.Ja.Text = (T 'server.dialog.jaWarten' $a.JaRest)
        $Ui.Hinweis.Text = (T 'server.dialog.wartehinweis' $a.JaRest) + ' ' + (T 'server.dialog.zeitHinweis' $a.TimeoutRest)
    }
    return $a
}

function Show-GuiBestaetigungsDialog {
    # Zeigt den Dialog modal und liefert 'ja', 'nein' oder 'zeit'. Alles außer einem Klick auf „Ja“ ist 'nein'.
    param([Parameter(Mandatory)][string]$Text)
    $ui = New-GuiBestaetigungsForm -Text $Text -Titel (T 'server.dialog.titel')
    $st = @{ Zeit = $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $tick = {
        $a = Update-GuiBestaetigungsForm -Ui $ui -Verstrichen $sw.Elapsed.TotalSeconds
        if ($a.Abgelaufen) { $st.Zeit = $true; $ui.Form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $ui.Form.Close() }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $ui.Form.Add_Shown({ $ui.Form.Activate(); $ui.Form.BringToFront() }.GetNewClosure())
    try {
        [void](Update-GuiBestaetigungsForm -Ui $ui -Verstrichen 0)
        $timer.Start()
        $r = $ui.Form.ShowDialog()
    }
    finally { $timer.Stop(); $timer.Dispose(); $ui.Form.Dispose() }
    if ($st.Zeit) { return 'zeit' }
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'ja' }
    return 'nein'
}

function Invoke-GuiBestaetigung {
    # Fragt nach, ohne Server-Kontext: Pause prüfen, Dialog zeigen ($Anzeige liefert 'ja'/'nein'/'zeit'), Ergebnis eintragen
    # und ins gui.log schreiben. Liefert @{ Ok; Ergebnis; PauseRest; NeuePause }. Ergebnis 'pause' = Dialog gar nicht gezeigt.
    param([Parameter(Mandatory)]$Zustand, [Parameter(Mandatory)][string]$Text, [scriptblock]$Anzeige = { param($t) Show-GuiBestaetigungsDialog -Text $t },
        [datetime]$Jetzt = (Get-Date))
    $was = Get-GuiDialogKurztext $Text
    $rest = Get-GuiDialogPauseRest -Zustand $Zustand -Jetzt $Jetzt
    if ($rest -gt 0) {
        [void](Add-GuiDialogErgebnis -Zustand $Zustand -Ergebnis 'pause' -Was $was -Jetzt $Jetzt)
        $n = [int]$Zustand.Verlauf[$Zustand.Verlauf.Count - 1].anzahl
        if (($n -eq 1) -or (($n % 10) -eq 0)) { Write-GuiLog "Dialog-Bremse: Anfrage ohne Dialog abgelehnt, Pause noch $rest s (Anfragen in der Pause: $n)" }
        return [pscustomobject]@{ Ok = $false; Ergebnis = 'pause'; PauseRest = $rest; NeuePause = 0 }
    }
    # Fail-closed: Ein Fehler im Dialog (kein Desktop, Forms nicht ladbar, Ausnahme) und jede unbekannte Antwort gelten als „nein“
    $erg = 'nein'
    try { $erg = [string](& $Anzeige $Text) }
    catch { Write-GuiLog ('Dialog-Fehler, als Ablehnung gewertet: ' + $_.Exception.Message) }
    if ($erg -cnotin 'ja', 'nein', 'zeit') { $erg = 'nein' }
    $neue = Add-GuiDialogErgebnis -Zustand $Zustand -Ergebnis $erg -Was $was -Jetzt (Get-Date)
    Write-GuiLog ("Dialog: $erg (Ablehnungen in Folge: " + [int]$Zustand.Ablehnungen + ')')
    if ($neue -gt 0) { Write-GuiLog "Dialog-Bremse: $($script:GuiDialogBisPause) Ablehnungen in Folge, Pause $neue s (Stufe $($Zustand.Stufe))" }
    [pscustomobject]@{ Ok = ($erg -ceq 'ja'); Ergebnis = $erg; PauseRest = 0; NeuePause = $neue }
}

function Get-GuiDialogVerlauf {
    # Für /api/session: neueste zuerst, höchstens $Max Einträge, nur Zeit, Ergebnis, Text, Anzahl.
    param($Zustand, [int]$Max = 20)
    if (-not $Zustand) { return @() }
    $l = @($Zustand.Verlauf.ToArray())
    [array]::Reverse($l)
    return @($l | Select-Object -First $Max | ForEach-Object { [ordered]@{ zeit = $_.zeit; ergebnis = $_.ergebnis; was = $_.was; anzahl = [int]$_.anzahl } })
}
