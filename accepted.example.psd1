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
#
# Beispiel (Befund-Text genau aus dem eigenen Bericht übernehmen):
#   @{ Check = 'BitLocker'; Match = '^Systemlaufwerk nicht verschlüsselt$'; Reason = 'Desktop zu Hause, bewusst zurückgestellt'; Until = '2027-04-30' }
@{
    Accepted = @(
    )
}
