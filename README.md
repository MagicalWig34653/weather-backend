# ShowerNow — Backend

Planungsrepository für die native, datensparsame Regen-App ShowerNow. Aktuelle App-Bundle-ID: `de.linolaske.showernow`; technisches Apple-Projekt und Repository-Namen bleiben Weather beziehungsweise `weather-apple`/`weather-backend`.

Zentraler optionaler Pushdienst mit Swift/Vapor, MariaDB und Docker Swarm. Kein PHP trotz des lokalen PhpstormProjects-Pfads. Backend-Implementierung folgt erst nach einer nutzbaren App. Keine Benutzerkonten, kein Dashboard und kein Self-Hosting-Produkt.

## Status

Dieses Repository enthält bewusst zunächst Dokumentation, keinen Anwendungscode und keine Build- oder Deployment-Konfiguration. Es ist noch kein ausführbares Projekt. Die Entwicklung ist freigegeben; aktueller Einstieg ist die Validierung der DWD-Datenkette gemäß [Entwicklungsplan](docs/plan.md).

## Einstieg

- [Entwicklungsplan](docs/plan.md)

- [Arbeitsstand und nächste Schritte](docs/status.md)

- [Aktuelle Entscheidungen und Roadmap](docs/decisions.md)
- [Ursprüngliches Konzept v2](docs/concept-v2.md)
- [Arbeitsanweisungen für Coding-Agenten](AGENTS.md)
- [Claude-Code-Einstieg](CLAUDE.md)

Die Apple-App wird zuerst entwickelt und intern über TestFlight erprobt. Der Pushdienst folgt danach. Schwesterrepository: [weather-apple](https://github.com/MagicalWig34653/weather-apple); aktueller App- und TestFlight-Stand im dortigen [Arbeitsstatus](https://github.com/MagicalWig34653/weather-apple/blob/main/docs/status.md).

## Lizenz

Open Source unter AGPLv3 ist vorgesehen. Die endgültige Lizenzfreigabe und die Vereinbarkeit mit der vorgesehenen App-Store-Veröffentlichung stehen noch aus. Derzeit ist keine Lizenz erteilt; insbesondere bedeutet ein öffentliches Repository allein keine Nutzungserlaubnis.
