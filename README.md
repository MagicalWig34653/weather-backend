# Weather — Backend

Planungsrepository für eine native, datensparsame Regen-App. Arbeitsname und technische Kennungen sind vorläufig.

Zentraler optionaler Pushdienst mit Swift/Vapor, MariaDB und Docker Swarm. Kein PHP trotz des lokalen PhpstormProjects-Pfads. Backend-Implementierung folgt erst nach einer nutzbaren App. Keine Benutzerkonten, kein Dashboard und kein Self-Hosting-Produkt.

## Status

Dieses Repository enthält bewusst zunächst Dokumentation, keinen Anwendungscode und keine Build- oder Deployment-Konfiguration. Es ist noch kein ausführbares Projekt. Die nächste Arbeit ist die gemeinsame Konzeption und die Validierung der DWD-Datenkette.

## Einstieg

- [Arbeitsstand und nächste Schritte](docs/status.md)

- [Aktuelle Entscheidungen und Roadmap](docs/decisions.md)
- [Ursprüngliches Konzept v2](docs/concept-v2.md)
- [Arbeitsanweisungen für Coding-Agenten](AGENTS.md)
- [Claude-Code-Einstieg](CLAUDE.md)

Die Apple-App wird zuerst entwickelt und intern über TestFlight erprobt. Der Pushdienst folgt danach. Geplantes Schwesterrepository: `weather-apple`.

## Lizenz

Open Source unter AGPLv3 ist vorgesehen. Die endgültige Lizenzfreigabe und die Vereinbarkeit mit der vorgesehenen App-Store-Veröffentlichung stehen noch aus. Derzeit ist keine Lizenz erteilt; insbesondere bedeutet ein öffentliches Repository allein keine Nutzungserlaubnis.
