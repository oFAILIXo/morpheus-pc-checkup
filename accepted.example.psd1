# Vorlage für die Akzeptanzliste. Zum Benutzen in "accepted.psd1" umbenennen bzw. kopieren.
#
# Hier trägst du Befunde ein, die auf DEINEM PC bewusst so gewollt sind. Sie erscheinen dann im
# Bericht als "Akzeptiert" statt als Warnung. Nichts eintragen, nur weil eine Warnung lästig ist.
#
#   Check  = Name der Prüfung wie im Bericht (Wildcards * erlaubt)
#   Match  = Regulärer Ausdruck, der auf den Befund-Text passen muss. Eng formulieren:
#            Ändert sich der Befund (z. B. ein weiteres Programm kommt hinzu), soll die Warnung zurückkehren.
#   Reason = Begründung (erscheint im Bericht)
#   Until  = optional, JJJJ-MM-TT. Danach wird der Punkt wieder gemeldet.
#   Id     = optional, 8 Hex-Zeichen; vergibt Morpheus selbst, wenn du in der Oberfläche akzeptierst.
#   Datei  = optional, voller Pfad einer einzelnen Datei (nur Prüfung "Systemdateien: Signaturen (Sigcheck)").
#   Sha256 = zu Datei gehörig, 64 Hex-Zeichen klein. Die Regel gilt nur, solange die Datei genau diesen Hash hat;
#            ändert sich die Datei, kommt die Warnung zurück.
#   Erstellt = optional, JJJJ-MM-TTTHH:MM:SS, wann die Regel angelegt wurde.
#
# Hinweis: Akzeptierst du in der Morpheus-Oberfläche, schreibt Morpheus diese Datei neu (Sicherung: accepted.psd1.bak).
# Deine Regeln bleiben erhalten, Kommentare gehen dabei verloren.
#
# Beispiel (Befund-Text genau aus dem eigenen Bericht übernehmen):
#   @{ Check = 'BitLocker'; Match = '^Systemlaufwerk nicht verschlüsselt$'; Reason = 'Desktop zu Hause, bewusst zurückgestellt'; Until = '2027-04-30' }
#   @{ Check = 'Datensicherung'; Match = '^Dateiversionsverlauf aus'; Reason = 'Sicherung per Synology Drive auf das NAS'; Until = '2027-10-31' }
@{
    Accepted = @(
    )
}
