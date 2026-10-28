# Projektkonzept: Native iOS-Regenradar-App mit datensparsamem Pushdienst

**Version:** 2.0  
**Stand:** 28. Oktober 2026  
**Status:** Diskussionsgrundlage für Codex – keine Implementierungsfreigabe

## 1. Ausgangslage und Projektziel

Es soll eine moderne, vollständig native iOS-Wetter-App entstehen, die RainToday für mich funktional ersetzt. Ausschlaggebend sind insbesondere die wahrgenommene Unzuverlässigkeit bisheriger Regeninformationen und der Wunsch nach nachvollziehbaren, möglichst aktuellen Niederschlagsdaten für Deutschland.

Die App konzentriert sich auf ein hochwertiges Regenradar, eine kurzfristige, standortbezogene Niederschlagsprognose und **optionale** Benachrichtigungen über bevorstehenden Regen. Wolken- und Satellitenbilder sind als spätere Erweiterung vorgesehen.

Das Projekt soll Open Source werden; **AGPLv3 ist die angestrebte Lizenz**, vorbehaltlich einer Prüfung der Vereinbarkeit der iOS-App-Veröffentlichung im App Store mit der gewählten Lizenz und gegebenenfalls erforderlicher Zusatzerlaubnisse.

Ein kostenpflichtiger Apple-Developer-Account ist vorhanden. Die App wird zunächst für den eigenen Gebrauch entwickelt, soll aber von Anfang an auf eine mögliche öffentliche Veröffentlichung ausgelegt sein.

### Leitprinzipien

- **Nativ statt Web-App:** SwiftUI und geeignete Apple-Frameworks; keine WebView-basierte Hauptoberfläche.
- **Radar zuerst:** Datenqualität und Aktualität sind wichtiger als Funktionsfülle.
- **Privacy by Design und by Default:** So wenig personenbezogene Daten wie technisch möglich.
- **Keine verpflichtenden Benutzerkonten:** Kein Login, keine E-Mail-Adresse, kein Nutzerprofil.
- **Optionale Infrastruktur:** Das Regenradar soll auch bei Ausfall des Push-Backends nutzbar bleiben.
- **Überschaubarer Betrieb:** Ein schlankes zentrales Backend statt einer Microservice-Landschaft.
- **Ehrlichkeit über Prognosen:** Messwerte, Vorhersagen, Datenalter und Unsicherheit müssen unterscheidbar sein.

## 2. Verbindlich getroffene Architekturentscheidungen

### 2.1 Native iOS-App

- Entwicklung mit **Swift und SwiftUI**.
- Kartenbasis **Apple MapKit**; für Rasteroverlays bei Bedarf `MKMapView` über eine native SwiftUI-Integration.
- **CoreLocation** für Standortfunktionen.
- Lokale Speicherung von Orten, benutzerseitigen Einstellungen und Cache mit geeigneten nativen Mechanismen (z. B. SwiftData und AppStorage).
- Radar- und Satellitenkarten werden grundsätzlich **direkt von den jeweiligen Wetterdatenanbietern** bezogen, nicht über den eigenen Server gestreamt.
- Das Push-Backend ist für die Nutzung der Karte **nicht erforderlich**.
- Kein verpflichtendes Nutzerkonto und keine zentrale Synchronisierung aller lokalen App-Daten.

### 2.2 Zentral betriebenes Backend

- **Kein Self-Hosting-Modell für Endnutzer.** Ein gemeinsames Backend wird vom Projektbetreiber betrieben.
- Bevorzugter Stack: **Swift, Vapor, MariaDB, Docker, Docker Swarm**.
- Backend ohne Web-Frontend, PWA oder Admin-Dashboard in der ersten Version.
- Keine Passkey-Benutzerkonten, keine QR-Kopplung und kein Backend-URL-Eingabefeld für Endnutzer.
- Die App nutzt eine fest definierte bzw. durch die App-Konfiguration bereitgestellte offizielle Backend-Adresse.
- Backend-Aufgaben: Registrierung für Push, Synchronisierung der tatsächlich abonnierten Warnorte, Radar-/Nowcast-Auswertung für Warnungen, Ereigniserkennung, Deduplizierung und APNs-Versand.
- Optional kann das Backend später eine **schlanke Punktprognose-API** anbieten, wenn dadurch App und Pushmeldungen konsistente Niederschlagswerte nutzen können. Das ist noch keine verbindliche MVP-Anforderung.

### 2.3 Betrieb und Skalierung

- Der Vapor-Dienst wird als **stateless Container** ausgelegt.
- Mehrere Docker-Swarm-Replikate sollen gleichzeitig laufen können.
- Gemeinsamer, persistenter Zustand liegt in MariaDB, nicht im Container-Dateisystem.
- API und Worker dürfen im selben Container-Image laufen; verteilte Jobs müssen durch Datenbankkoordination abgesichert werden.
- Keine zusätzlichen Infrastrukturkomponenten wie Redis oder RabbitMQ, solange ein belastbarer Betrieb mit MariaDB möglich ist.
- Konfiguration der Serverdienste durch **ENV**; vertrauliche Inhalte über Docker Secrets bzw. über ENV referenzierte Secret-Dateien.
- Keine öffentliche Datenbankverbindung. HTTPS ist verpflichtend.

## 3. Wetterdatenquellen und Qualität

### 3.1 Deutscher Wetterdienst (DWD) – Primärquelle

Zu prüfen und möglichst zu nutzen:

- Offizielle deutsche Niederschlagsradardaten.
- Aktuelle Radarbilder und Animationen vergangener Zeitpunkte.
- Kurzfristige Niederschlagsvorhersage (Nowcast), insbesondere RADVOR-RV oder andere geeignete DWD-Produkte.
- Ziel: zeitliche Auflösung von etwa fünf Minuten und ein Prognosehorizont bis ungefähr zwei Stunden, **soweit vom gewählten Datenprodukt tatsächlich unterstützt**.
- Für die Kartendarstellung: DWD-WMS oder andere offizielle Kartenschnittstellen.
- Für numerische Warnungsberechnung: möglichst die offiziell bereitgestellten Radar-/Nowcast-Rohdaten.

Vor der Implementierung sind Live-Erreichbarkeit, genaue Layernamen, Zeitparameter, Dateiformate, räumliche Abdeckung, Aktualisierungsintervalle, Nutzungsbedingungen und Quellennachweise zu verifizieren. Keine Produktannahme soll ungeprüft als garantiert gelten.

### 3.2 EUMETSAT – optionale Erweiterung

- Satelliten- und Wolkenbilder für Deutschland und Europa.
- Optional zeitliche Animation und passende Tag-/Nachtansichten.
- Erst nach einer stabil funktionierenden Regenradar-Grundversion priorisieren.
- Produktbezogene Lizenzen und Quellenhinweise prüfen.

### 3.3 Alternative Datenquellen

- Andere Quellen dürfen als technischer Fallback oder zur Evaluierung untersucht werden.
- Eine experimentelle Community-API darf **nicht stillschweigend zur einzigen kritischen Abhängigkeit** für automatische Regenwarnungen werden.
- Kostenpflichtige APIs nach Möglichkeit vermeiden.

### 3.4 Nachvollziehbare Zuverlässigkeit

- Auf der Karte und in Prognosen den **tatsächlichen Datenzeitpunkt** anzeigen.
- Messung, Nowcast und sonstige Vorhersage optisch und semantisch unterscheiden.
- Bei veralteten oder fehlenden Daten sichtbar warnen und keine scheinbar aktuelle Präzision suggerieren.
- Später Messungen gegen vorangegangene Prognosen auswerten, um Fehlalarme, verpasste Regenereignisse und Zeitabweichungen messbar zu machen.

## 4. Anforderungen an die iOS-App

### 4.1 Benutzeroberfläche

- Modernes, übersichtliches SwiftUI-Design nach aktuellen Apple-Konventionen.
- Light und Dark Mode, gute Bedienbarkeit mit einer Hand.
- Deutsche Oberfläche; spätere Lokalisierung technisch vorbereiten.
- Flüssige Karten- und Timeline-Animationen.
- Kein Nachbau geschützter UI-Elemente oder des Markenauftritts anderer Apps.

### 4.2 Regenradar und Karte

- Interaktive Apple-Karte mit transparentem Regenradar-Layer.
- Zoomen, Verschieben, Standortzentrierung und Anzeige gespeicherter Orte.
- Animation vergangener Radarbilder und zukünftiger Nowcast-Zeitpunkte.
- Zeitleiste mit Play/Pause und erkennbarer Grenze zwischen Vergangenheit und Vorhersage.
- Sinnvolles Caching, kontrollierte Abrufintervalle und sparsamer Netzwerkverbrauch.
- Zeitstempel und Anzeige der Datenaktualität.
- Verständliche Fehlerzustände bei Netzwerk- oder Quellenproblemen.

### 4.3 Niederschlagsprognose am Ort

- Anzeige von voraussichtlichem Regenbeginn, Regenende und Regenintensität, soweit aus den verfügbaren Daten seriös ableitbar.
- Verlauf über die nächsten ungefähr zwei Stunden.
- Verständliche Darstellung von Unsicherheit und Datenalter.
- Technisch offen ist, wie numerische Punktwerte auf dem Gerät am effizientesten bereitgestellt werden: direkte Datenquelle, begrenzte lokale Auswertung oder optionale Punktprognose-API des eigenen Backends.

### 4.4 Feste Orte

- Beliebige feste Orte über Suche oder Karte hinzufügen, benennen, bearbeiten und löschen.
- Ortsnamen wie „Zuhause“ und „Arbeit“ bleiben **ausschließlich lokal** auf dem iPhone.
- Ortsdaten und Anzeigeeinstellungen werden lokal gespeichert.
- Nutzer können **pro Ort separat** automatische Regenwarnungen aktivieren.
- Ausschließlich für aktivierte Warnorte erforderliche Informationen werden an das Backend übertragen.
- Einstellungen können insbesondere Vorwarnzeit, Mindestintensität, Warnungsarten und Ruhezeiten umfassen.

### 4.5 Aktueller Standort

Zwei getrennte Funktionen:

1. **Standort bei App-Nutzung:** zur Kartenzentrierung und lokalen Regenprognose; keine Serverregistrierung notwendig.
2. **Optionale Unterwegs-Regenwarnungen:** Ein dynamisches Warnabonnement, dessen Position bei relevanten Ortsänderungen aktualisiert wird.

Für die zweite Funktion:

- Niedriger Akkuverbrauch hat hohe Priorität.
- Apples Significant-Change Location Service und gegebenenfalls weitere geeignete sparsame Verfahren evaluieren.
- Kein dauerhaftes GPS-Tracking und keine künstlich permanent laufende Hintergrundortung.
- Erweiterte Standortberechtigungen nur nach ausdrücklicher Aktivierung und verständlicher Erklärung anfordern.
- Die zuletzt übermittelte Position mit Aktualisierungszeitpunkt verwalten; alte Daten nicht als garantiert aktuellen Aufenthaltsort darstellen.
- iOS-Grenzen beachten: Hintergrundereignisse und Aktualisierungszeitpunkte sind **nicht garantiert**.
- Der Nutzer kann die Funktion jederzeit ausschalten und die zugehörigen Serverdaten löschen.

### 4.6 Optionaler Pushmodus

Die App soll sinnvoll nutzbar sein, wenn die Nutzer Pushberechtigungen ablehnen. Lokale Hinweise während der App-Nutzung sind möglich. Zeitkritische automatische Warnungen bei geschlossener App werden primär über das Backend und APNs bereitgestellt. Nicht zusätzlich ein zweites unkoordiniertes System lokaler zeitgesteuerter Warnungen aktivieren.

## 5. Zentrale Push-Architektur

### 5.1 Geräteidentität ohne Benutzerkonto

- Bei aktivierten Pushwarnungen registriert sich **eine konkrete App-Installation** beim Backend.
- Die App verwaltet eine zufällige Installationskennung und ein starkes Installationsgeheimnis; Geheimnisse werden im iOS-Keychain geschützt.
- Der aktuelle APNs-Token dient ausschließlich der Zustellung und **nicht** als alleiniger Berechtigungsnachweis.
- Änderungen an Abonnements benötigen eine gesicherte installationsbezogene Authentifizierung.
- APNs-Tokens können wechseln und müssen aktualisierbar sein.
- Apple App Attest als zusätzlicher Missbrauchsschutz prüfen; es ersetzt keine serverseitige Autorisierung.
- Jede Installation verwaltet eigene Abonnements. Geräteübergreifende Kontosynchronisierung gehört nicht zum MVP.

### 5.2 Abonnements und Zustellung

- Zuordnung: Installation → aktive Warnabonnements → erforderliche Radarbereiche → APNs-Token.
- Ein Gerät kann mehrere feste Warnorte und höchstens einen dynamischen Warnort überwachen.
- Ähnliche oder überlappende Orte auf demselben Gerät dürfen nicht zu doppelten Meldungen führen.
- Beim Löschen oder Deaktivieren eines Abonnements muss die Änderung serverseitig nachvollziehbar bestätigt werden.
- Für einzelne Regenereignisse nicht mehrfach warnen; geeignete Cooldowns und Ereigniskennungen verwenden.
- Keine Warnungen auf Grundlage eindeutig veralteter Daten versenden.
- APNs-Fehler, ungültige Token und abgelaufene Warnungen behandeln.
- APNs bietet keine absolute Zustellgarantie; auch die serverseitige Verarbeitung kann trotz Idempotenzschutz in Grenzfällen zu doppelten Zustellungen führen.

### 5.3 Wetterverarbeitung

- DWD-Rohdaten **zentral und nicht einmal pro Nutzer** abrufen.
- Bei neuen Datenläufen die relevanten Rasterbereiche bzw. prognostizierten Werte bestimmen.
- Gleiche Rasterzellen möglichst nur einmal meteorologisch auswerten.
- Individuelle Schwellen und Vorwarnzeiten erst anschließend pro Abonnement anwenden.
- Eine wiederverwendbare Swift-Kernbibliothek für Regenereignisregeln und gemeinsame Datenmodelle prüfen.
- HDF5-/ODIM-Verarbeitung ist ein gesondert zu untersuchendes Implementierungsrisiko; ein eng begrenzter Parser in einer anderen Sprache ist bei handfestem Vorteil akzeptabel.

### 5.4 Replikation und Koordination

- Statelesse Vapor-Replikate mit gemeinsamem MariaDB-Zustand.
- Datenbankbasierte Job-Leases zur koordinierten Verarbeitung neuer Radarprodukte.
- Persistente Push-Outbox, deduplizierende Schlüssel und begrenzte Wiederholungsversuche.
- Worker dürfen bei Ausfall und Neustart wiederaufgenommen werden.
- Keine langen Datenbanktransaktionen während externer Netzwerkanfragen.
- Migrationen nur kontrolliert, nicht parallel bei jedem Replikatstart.
- Swarm-Skalierung des Anwendungsdienstes bedeutet **nicht automatisch** Hochverfügbarkeit der Datenbank. Diese ist gesondert zu betrachten.

## 6. Datenschutz- und Sicherheitskonzept

### 6.1 Grundsatz

Das Backend wird zentral betrieben. Deshalb muss das System **nachprüfbar datensparsam** gebaut werden. Ein Versprechen „Wir tracken nicht“ allein ist unzureichend; die tatsächliche technische Möglichkeit zur Verknüpfung von Geräte- und Standortdaten muss ehrlich kommuniziert werden.

- Ohne aktivierte Pushabonnements **keine App-Installationsregistrierung und keine Speicherung von Standorten im eigenen Push-Backend**.
- Direkte Netzwerkzugriffe der App auf DWD, Apple-Kartendienste oder andere Datenanbieter bestehen unabhängig davon und sind transparent zu erläutern.
- Keine Werbe-IDs, Werbe- oder Analyse-SDKs, Bewegungsprofile, E-Mail-Adressen oder verpflichtenden Nutzerkonten.
- Zweckbindung sämtlicher serverseitiger Daten ausschließlich an Warnungsbetrieb und Sicherheitsfunktionen.
- Infrastruktur- und Sicherheitslogs ebenfalls datensparsam gestalten.

### 6.2 Standortdaten minimieren

- **Exakte GPS-Koordinaten und benutzerdefinierte Ortsnamen bleiben auf dem Gerät**, soweit technisch möglich.
- Für serverseitige Warnungen soll die App vorzugsweise nur die passende **DWD-Rasterzellenkennung oder eine äquivalente, möglichst grobe räumliche Referenz** übermitteln.
- Zellprojektion, Rasterversion und Randfälle müssen zwischen App und Backend konsistent festgelegt werden.
- Eine Rasterzelle um etwa einen Kilometer ist weiterhin potenziell **personenbezogen** und nicht anonym.
- Für dynamische Warnorte nur die **zuletzt übermittelte** Zelle plus erforderlichen Zeitstempel/Status speichern; keinen Bewegungsverlauf.
- Keine fortlaufende Historie dynamischer Positionen in Debuglogs, Jobdaten, Metriken, Backups oder Audit-Events aufbauen.
- Die Auswirkungen wechselnder Rasterzellen auf die Warnqualität sowie die Zuordnung bei Zellgrenzen prüfen.

### 6.3 Datenspeicherung und Löschung

- APNs-Tokens und installationsbezogene Geheimnisse angemessen geschützt speichern; Berechtigungen begrenzen und Geheimnisse nicht im Klartext loggen.
- Sichere Kommunikation über HTTPS.
- API-Änderungen ausschließlich nach installationsbezogener Autorisierung.
- Missbrauchsschutz für Registrierung und API, ohne zusätzliche dauerhafte Identifizierungsmerkmale zu erzeugen.
- Nutzer können in der App sehen, **welche Abonnements und Radarbereiche** serverseitig gespeichert sind.
- Abonnements, dynamische Position und gesamte Installation lassen sich serverseitig löschen.
- Automatische Bereinigung ungültiger APNs-Tokens und inaktiver Installationen nach transparenten, definierten Fristen.
- Löschkonzept muss auch Datenbankbackups und deren Aufbewahrungsfristen berücksichtigen.
- Keine öffentliche Anzeige interner Geräte-, Token- oder Standortdaten.

### 6.4 Transparenz und Rechtliches

- Verständliche Datenschutzinformationen **vor** erstmaliger Aktivierung der Serverwarnungen.
- In den App-Store-Datenschutzangaben die tatsächlich übermittelten Daten und Zwecke korrekt deklarieren.
- Keine Behauptung vollständiger Anonymität oder technischer Unmöglichkeit von Tracking.
- Apples „Tracking“ im Sinne von App Tracking Transparency ist von der allgemeinen Verarbeitung personenbezogener Daten zu unterscheiden.
- DSGVO-Pflichten einschließlich Rechtsgrundlage, Informationspflichten, Speicherfristen, Betroffenenrechten und ggf. Auftragsverarbeitung für den Hostinganbieter rechtlich prüfen.
- Der veröffentlichte Quellcode unter AGPLv3 soll die Verarbeitung nachvollziehbar machen, ersetzt aber weder Datenschutzmaßnahmen noch die tatsächliche Produktionsdokumentation.

## 7. Grobes Datenmodell und API

### Erwartete Datenbereiche in MariaDB

- **Installationen:** pseudonyme Kennungen, Zustellinformationen, Authentifizierungszustand.
- **Abonnements:** Installation, Radarbereich, Schwellen, Ruhezeiten und Aktivierungsstatus.
- **Dynamischer Warnort:** aktueller Radarbereich und Aktualitätsinformation – keine Historie.
- **Radarverarbeitung:** Version und Status verarbeiteter Wetterläufe.
- **Ereignisse und Warnungszustand:** erkannte Regenphasen und Deduplizierungsinformation.
- **Push-Outbox:** zuzustellende, zugestellte und fehlgeschlagene Aufträge.
- **Worker-Leases:** zeitlich begrenzte Koordination zwischen Replikaten.

Die finale Normalisierung und Anzahl der Tabellen bleiben offen; **keine Ortsnamen zentral speichern**, sofern keine spätere ausdrücklich freigegebene Funktion dies benötigt.

### Erwartete REST-API-Funktionen

- App-Installation registrieren und authentifizieren.
- APNs-Token aktualisieren.
- Feste Warnabonnements anlegen, bearbeiten, abrufen und löschen.
- Dynamischen Warnort aktualisieren oder deaktivieren.
- Alle serverseitig gespeicherten eigenen Abonnements transparent anzeigen.
- Installation samt zugehöriger Daten löschen.
- Health- und Readiness-Endpunkte für den Betrieb.
- Optional später: numerische Punktprognose für ausgewählte Orte.

Der konkrete Endpunktzuschnitt und das Authentifizierungsprotokoll sollen vor der Umsetzung konzipiert und sicherheitsorientiert geprüft werden.

## 8. Betrieb und Administration

- Zentrales, vom Projektbetreiber betriebenes Backend.
- Docker-Image mit schlankem Produktionslaufzeitprofil und geeigneten Healthchecks.
- Swarm-taugliche, stateless API-/Worker-Replikate.
- MariaDB auf persistentem und gesichertem Storage.
- Automatische Wiederaufnahme unterbrochener Aufgaben und kontrollierte Rolling Updates.
- Strukturierte, datensparsame Logs; keine Anwendungsgeheimnisse, Geräte-Token, Radarstellen oder Standortdaten in Standardlogs.
- Konfiguration der Betriebsparameter nur über ENV, sensible Werte vorzugsweise als Docker Secrets.
- Kein PWA-, Svelte-, Passkey-, Self-Hosting- oder Multi-Tenant-Verwaltungssystem vorgesehen.
- Ohne Frontend müssen notwendige Betreiberfunktionen über CLI und/oder abgesicherte interne Betriebswerkzeuge möglich sein.

## 9. Nicht-Ziele der ersten Version

- Self-Hosting durch Endnutzer oder frei konfigurierbare Backend-URLs.
- Web-Frontend oder PWA zur Geräte-/Benutzerverwaltung.
- Benutzerkonten, Passkeys, Login, Haushalts-/Gruppenfreigaben und Cloud-Synchronisierung.
- Werbetracking, Nutzerprofile oder Bewegungsverläufe.
- Dauerhaftes hochfrequentes GPS-Tracking.
- Serverbetrieb für sämtliche Kartenbilder oder ein vollständiges Wetterportal.
- Langfristige eigene Wettermodelle.
- Komplexe Microservices, Redis oder Message Broker ohne nachgewiesenen Bedarf.
- Garantierte minutenexakte Hintergrundausführung auf iOS oder garantierte APNs-Zustellzeiten.
- Umfangreiche Wolken-/Satellitenansichten vor einer zuverlässigen Regenradar-Grundversion.

## 10. Grobe Meilensteine

**Phase 1 – Daten und Risiken validieren**

- Tatsächliche DWD-Kartendienste, Radar-Nowcast-Rohdaten und Nutzungslizenzen prüfen.
- Prototypische Auswertung eines realen DWD-Datenlaufs für ausgewählte Rasterzellen.
- Früh prüfen, ob eine konsistente, für iOS bezahlbare Punktprognose ohne Backend möglich ist.
- Datenschutz- und App-Store-Risiken dokumentieren.

**Phase 2 – Native Radar-App**

- SwiftUI-/MapKit-Kartenansicht, Radaranimation und Timeline.
- Standortanzeige, lokale Orte, Prognoseanzeige, Datenalter und Cache.
- Ohne Push-Backend eigenständig nutzbare Radar-App.

**Phase 3 – Minimaler Pushdienst**

- Vapor, MariaDB, installationsbezogene Authentifizierung, APNs.
- Datenschutzarme Rasterzellen-Abonnements und eine einfache Regenbeginn-Warnung.
- Zentraler Radarlauf, Jobkoordination und Outbox.
- Bereits in der Grundstruktur Swarm-replizierbar.

**Phase 4 – Qualität und Unterwegs-Warnungen**

- Fehlalarme und Prognoseabweichungen messen und reduzieren.
- Deduplizierung bei nahegelegenen Orten optimieren.
- Energiesparende iOS-Hintergrundortung und dynamischen Warnort optional ergänzen.
- Datenexport/-einsicht, Löschung und Lifecycle-Bereinigung überprüfen.

**Phase 5 – Erweiterungen und Veröffentlichung**

- EUMETSAT-Satellitenbilder, gegebenenfalls Widgets und weitere Warnungsarten.
- Performance, Energieverbrauch, Sicherheit, Datenschutzdokumentation und App-Store-Release prüfen.

## 11. Offene Architekturfragen für die weitere Diskussion

1. **DWD-Daten:** Welche konkreten, aktuell verfügbaren Produkte liefern zuverlässig numerische Zwei-Stunden-Nowcasts und welche Formate eignen sich in Swift/Linux?
2. **Punktprognosen in der App:** Soll die App numerische Werte vollständig unabhängig vom Backend beziehen können, oder genügt eine optionale Backend-API mit klarem Fallback?
3. **Raster-/Standortschutz:** Welche räumliche Auflösung und welche technische Rasterzellkodierung sind für die Warnqualität nötig, ohne unnötige Präzision zu übertragen?
4. **Installationsauthentifizierung:** Welches einfache, widerrufbare Protokoll ist ohne Benutzerkonto sicher und robust gegen Reinstallation und Missbrauch?
5. **Warnungsqualität:** Wie definieren wir Regenbeginn, Intensitätsschwellen, Ereignisidentität, Deduplizierung, Datenalter und Ruhezeiten?
6. **Dynamischer Standort:** Welche Hintergrundstandortstrategie liefert unter iOS den besten Kompromiss aus Akkuverbrauch, Datenschutz und Genauigkeit?
7. **Datenlöschung:** Welche konkreten Aufbewahrungsfristen sind sinnvoll und wie werden Backups und technische Protokolle berücksichtigt?
8. **AGPLv3/App Store:** Welche zusätzlichen Lizenzhinweise oder Ausnahmen sind gegebenenfalls erforderlich?
9. **Skalierung:** Wann reichen MariaDB-basierte Leases und eine gemeinsame Outbox, und ab welcher Last müsste die Architektur angepasst werden?

## 12. Arbeitsauftrag an Codex

Du unterstützt mich bei der **weiteren Planung und technischen Konzeption**, bevor Anwendungscode entsteht.

Bitte:

1. Bewerte das vorliegende Konzept hinsichtlich Machbarkeit, Risiken, Wartbarkeit und Datenschutz.
2. Prüfe besonders die DWD-Datenkette, iOS-Hintergrundbeschränkungen, die sichere Gerätezuordnung ohne Login, APNs und den stateless Swarm-Betrieb.
3. Trenne **bestätigte technische Möglichkeiten, offene Annahmen und ausdrücklich zu testende Hypothesen**.
4. Schlage ein kleines, belastbares MVP sowie die sinnvolle Reihenfolge der technischen Validierungen vor.
5. Empfiehl Alternativen nur, wenn sie klar erkennbare Vorteile bieten; vermeide Overengineering.
6. Behandle die Datenschutzarchitektur als Produktanforderung, nicht als nachträglichen Dokumentationsschritt.
7. Stelle zentrale offene Architekturentscheidungen zur Diskussion, bevor du sie festlegst.
8. **Schreibe vorerst keinen Anwendungscode, keine Docker-Konfiguration und keine vollständige Implementierung.**

Beginne mit einer strukturierten Bewertung und nenne die **fünf wichtigsten Punkte, die wir als Nächstes gemeinsam entscheiden oder technisch verifizieren sollten**.
