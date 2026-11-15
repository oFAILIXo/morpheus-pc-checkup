# Sicherheit / Security

## Deutsch

### Sicherheitslücke melden

Bitte melde Sicherheitslücken **nicht** als öffentliches Issue. Nutze stattdessen die private Meldung von GitHub: im Repository `oFAILIXo/morpheus-pc-checkup` unter „Security“ › „Report a vulnerability“ (Private vulnerability reporting). Beschreibe kurz, was du gefunden hast, wie man es nachstellt und welche Windows- und Morpheus-Version betroffen ist. Gib keine echten Berichte mit persönlichen Daten an.

### Unterstützte Versionen

Sicherheitskorrekturen gibt es nur für die **neueste veröffentlichte Version**. Ältere Versionen bitte zuerst aktualisieren.

### Nicht im Geltungsbereich

- Bekannt und dokumentiert: Morpheus ist nicht code-signiert und wird mit `-ExecutionPolicy Bypass` gestartet.
- Angriffe, die schon Administratorrechte voraussetzen.
- Das Sitzungstoken schützt nicht vor Prozessen desselben Benutzers (siehe „Sicherheit der GUI“ in der README).
- Befunde in Windows, Defender, winget oder anderen Programmen, die Morpheus nur anzeigt oder aufruft.
- Veränderte Kopien, Forks und Downloads, die nicht von den offiziellen Releases stammen.

## English

### Reporting a vulnerability

Please do **not** report security vulnerabilities as a public issue. Use GitHub's private reporting instead: in the repository `oFAILIXo/morpheus-pc-checkup` under “Security” › “Report a vulnerability” (private vulnerability reporting). Briefly describe what you found, how to reproduce it and which Windows and Morpheus version is affected. Do not attach real reports containing personal data.

### Supported versions

Security fixes are only provided for the **latest released version**. Please update older versions first.

### Out of scope

- Known and documented: Morpheus is not code-signed and is started with `-ExecutionPolicy Bypass`.
- Attacks that already require administrator rights.
- The session token does not protect against processes of the same user (see “GUI security” in the README).
- Findings in Windows, Defender, winget or other programs that Morpheus only displays or calls.
- Modified copies, forks and downloads that do not come from the official releases.
