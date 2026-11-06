# Dashboard (Frontend)

Betreiber-Oberfläche des Radar-Backends: SvelteKit (Svelte 5, TypeScript, `adapter-static`, SPA-Fallback), Tailwind 4, shadcn-svelte. Plan: `docs/dashboard-plan.md` (Abschnitt 6). Der Build ist rein statisch, wird im Backend-Image unter `/app/dashboard` abgelegt und vom Backend unter `/dash` ausgeliefert. Es gibt keine Laufzeit-Netzzugriffe und keine CDNs; Inter Variable (OFL, Latin-Teilsatz) liegt lokal unter `src/lib/design/fonts/`.

## Befehle (Node >= 22, getestet mit 26)

```sh
npm ci                # exakt nach package-lock.json
npm run dev:mock      # Entwicklung mit Mock-Backend (erfundene Daten, Build-Konstante __MOCK__)
DASH_API_TARGET=http://127.0.0.1:8081 npm run dev   # Entwicklung gegen ein echtes Backend (Proxy auf /dash/api)
npm run check         # svelte-check
npm run lint          # Prettier + ESLint
npm test              # Vitest (API-Client, Formularlogik, Protokoll, Polling, Vertragstests gegen docs/fixtures, Mock-Form)
npm run test:e2e      # Playwright gegen den Mock-Server: axe (WCAG 2.2 AA) je Seite und Zustand, hell/dunkel, Desktop/Telefon, Abläufe (Konfiguration, Protokoll, Geräte, Anmeldung)
node scripts/screenshots.mjs <Ordner> [Seiten] [normal|empty|error|slow]  # Screenshots (Mock-Server auf :5199 nötig)
npm run build         # statischer Build nach build/ inkl. CSP-Nachbearbeitung
```

Im Mock-Modus wählt `?mock=setup|closed|login|auth` den Anfangszustand, `?mockstate=empty|slice1|error|slow|limited|pairopen|pairending` den Datenzustand (`limited`: Schreibzugriffe antworten 429; `pairopen`/`pairending`: Kopplungsfenster offen bzw. kurz vor Ablauf) und `?mockcmd=failed|expired` das Ergebnis von Geräteaufträgen.

**Echte Daten statt Mock:** Ohne `--mode mock` ist `__MOCK__` eine Literalkonstante `false`; die Datenschicht (`src/lib/client.ts`) nutzt dann `fetch` gegen `/dash/api`. Der Mock, die Passkey-Attrappe, das Mock-Banner und die Design-Vorschau (`/dash/_design`) fehlen im Produktionsbuild; `scripts/postbuild.mjs` bricht den Build ab, wenn Marker davon (Texte, Dateinamen) auftauchen. `npm run dev` mit `DASH_API_TARGET` leitet `/dash/api` an ein Backend weiter und setzt `Origin` auf das Ziel; die Passkey-Anmeldung braucht dafür `DASH_ORIGIN`/`DASH_RP_ID` passend zum Zielhost (nicht geprüft; im Betrieb liefert das Backend das Frontend selbst unter `/dash`).

## Vertrag und Tests

Maßgeblich ist `docs-site/content/dashboard-api.md` (camelCase, Fehler als `{"error":"<code>"}`; Texte wählt der Client nach Code, `src/lib/errors.ts`). `src/lib/contract.test.ts` lässt jede Fixture aus `docs/fixtures/manifest.json` durch Client und Datenschicht laufen (Erfolg: unveränderte Antwort, Pfad, Methode, Body; Fehler: Status, Servercode, Klartext, Retry-After), `src/lib/mock.test.ts` prüft die Form des Mocks gegen die Fixtures. Bekannte Vertragslücken: der Vertrag nennt keinen Akteur im Protokoll (abgeleitet: nur `reset_cli` ist Kommandozeile), keine Seitenverschiebung (`limit` höchstens 200, Seiten werden clientseitig gebildet) und keine erlaubten Werte für `enum`-Einträge (`choices` wird genutzt, falls der Server sie additiv liefert; sonst Textfeld).

## Designsystem (WP10)

Sprache wie timetrack-pwa: Zinc-Neutrale in OKLCH, ein blauer Akzent, semantische Status-Töne (ok/warn/err, immer mit Icon und Text), Inter Variable mit `tabular-nums`. Tokens (hell/dunkel) stehen in `src/routes/layout.css`.

- `src/lib/design/`: Shell (Seitenleiste ab 768 px, untere Tab-Leiste auf dem Telefon, Kopfzeile mit Zeitbereich/Aktualisieren/Auto-Refresh/Sitzung), Panel, Kpi, StatusBadge/StatusDot, DataTable, Segmented, Loadable (Lade-/Fehler-/Veraltet-Zustand je Widget), Empty/Error/Stale/Skeleton, Toaster, ConfirmDialog. Vorschau: `/dash/_design` (nur Dev/Mock).
- `src/lib/charts/`: eigene SVG-Bausteine ohne Chartbibliothek: XYChart (Linie, Fläche, Balken, gestapelt), RankBars, HeatStrip/Heatmap, Donut, Sparkline. Tooltip per Zeiger und Pfeiltasten, Umschalter „Tabelle“.
- `src/lib/insights/`: Datenzugriffsschicht. `api.ts` kennt als einzige Stelle die Insights-Routen, `types.ts` die Formen, `mock.ts` die erfundenen Daten (`?mockstate=empty|error|slow`). Seiten rufen nur `insights.*`.
- Zeitbereich (`?range=24h|7d|30d`) und Auto-Refresh (30 s, Polling) sind globaler Zustand (`design/context.svelte.ts`).

## Struktur

- `src/lib/api.ts`: API-Vertrag als TypeScript-Typen und typisierter Client (`/dash/api`, CSRF-Token nur im Speicher). Maßgeblich bleibt `docs-site/content/dashboard-api.md` (WP5).
- `src/lib/passkey.ts`: WebAuthn im Browser (`navigator.credentials`, Base64URL-Wandlung).
- `src/lib/mock.ts`: Mock-Backend. `src/lib/components/ui/`: shadcn-svelte-Komponenten (unverändert bis auf `data-[state=…]`, siehe unten).
- `src/routes/`: Übersicht, Betrieb, Traffic, Push, Abos, Geräte, Konfiguration, Protokoll; Anmeldung/Einrichtung erscheinen anstelle der Seiten, solange keine Sitzung besteht.
- `scripts/postbuild.mjs`: Nachbearbeitung für die CSP (siehe unten).

## CSP-Befund (geprüft am 3.11.2026 in Chromium, Prüfstand mit Header)

Richtlinie ohne `unsafe-inline` und ohne `style-src-attr`:

```
default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self';
connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'
```

Ergebnis: alle Seiten, Dialog (bits-ui), Tabs und Diagramme laufen ohne Verletzung. Zwei Fundstellen mussten behoben werden:

1. SvelteKit schreibt ein Inline-Startskript in `index.html`. `scripts/postbuild.mjs` lagert es in `_app/immutable/boot.<hash>.js` aus. Damit entfällt die Hash-Liste im Header; `kit.csp` wird nicht benötigt.
2. Der Routen-Ansager `#svelte-announcer` trägt ein `style`-Attribut im Client-Code (würde `style-src-attr` erzwingen). Das Skript ersetzt es durch die Tailwind-Klasse `sr-only`. Findet es den Text nicht mehr (SvelteKit geändert), bricht der Build ab.

Der Build prüft zusätzlich, dass `index.html` weder Inline-Skripte noch `style`-Attribute oder externe Adressen enthält. Weitere Bibliotheken setzen Stile nur über CSSOM (erlaubt). Nicht geprüft: Safari und Firefox mit dieser Richtlinie.

## Herkunft und Lizenzen

shadcn-svelte (MIT) kopiert den Komponentenquelltext ins Projekt: Button, Card, Input, Label, Table, Badge, Alert, Dialog, Tabs, Separator (CLI 1.8.0, Vorlage „vega“, Basisfarbe neutral; `components.json` mit Alias `#lib`). Abweichung: Die Zustandsauswahl in Tabs und Dialog nutzt `data-[state=active|open|closed]`, weil bits-ui 2.x diese Attribute setzt (nicht `data-active`). Laufzeitabhängigkeiten im Bundle: svelte, @sveltejs/kit (MIT), bits-ui (MIT), @lucide/svelte (ISC), tailwind-variants, clsx, tailwind-merge (MIT), @internationalized/date (Apache-2.0). Alle Versionen sind exakt gepinnt, `package-lock.json` ist eingecheckt.

## `npm audit`

`npm audit --omit=dev` ist sauber (alle Pakete sind Build-Werkzeuge, nichts davon läuft im Image). Gesamtprüfung meldet `deepmerge` (Prototype Pollution, transitiv über `@sveltejs/vite-plugin-svelte`): betrifft nur das Build-Werkzeug mit eigener Konfiguration, kein Laufzeitcode; wird mit Updates der Abhängigkeiten behoben.
