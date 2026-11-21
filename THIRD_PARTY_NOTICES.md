# Drittanbieter-Lizenzen

Das Radar-Backend baut auf Swift-Paketen auf, die über SwiftPM eingebunden werden. Die Lizenz- und Hinweistexte (`LICENSE*`, `NOTICE*`, `COPYING*`, `UNLICENSE`) aller in `Package.resolved` festgelegten Pakete liegen unverändert in [`third-party-licenses/`](third-party-licenses/), je Paket ein Ordner. `third-party-licenses/INDEX.txt` nennt je Paket Version, Revision und Quelle (aus `Package.resolved`). Zusätzlich liegt dort die Lizenz des in swift-nio mitgelieferten llhttp (`swift-nio/LICENSE.CNIOLLHTTP`).

- **Umfang:** Es sind alle aufgelösten Pakete aufgeführt (Obermenge). Welche davon tatsächlich ins Release-Binary gelinkt werden, wurde nicht einzeln geprüft.
- **Texte unverändert:** Die Dateien stammen aus den SwiftPM-Checkouts (`.build/checkouts`) der aufgelösten Versionen; nichts davon wurde bearbeitet oder ergänzt. Das gilt auch für die `NOTICE.txt` von swift-nio-ssl (nennt BoringSSL weiterhin „Combination ISC and OpenSSL license“).
- **Runtime-Image:** Das Dockerfile erzeugt die Sammlung im Build-Stage aus den dort tatsächlich aufgelösten Checkouts und legt sie mit dieser Datei nach `/licenses/` im Image (`/licenses/<paket>/…`, `/licenses/INDEX.txt`).
- **Aktualisieren** (nach jeder Änderung an `Package.resolved`, nach `swift package resolve`):
  `sh tools/collect-third-party-licenses.sh .build/checkouts Package.resolved third-party-licenses`
- **Nicht enthalten:** Systembibliotheken des Runtime-Images (Ubuntu-Pakete wie libwebp, libcurl, libxml2, zlib, libbz2) mit eigenen Lizenzen unter `/usr/share/doc/<paket>/copyright` im Image sowie die Swift-Laufzeit (statisch gelinkt, `--static-swift-stdlib`; Lizenz des Swift-Projekts) und der Dashboard-Build (npm-Pakete). Dafür liegt hier keine Sammlung vor.

Dies ist eine Zusammenstellung der vorhandenen Texte, keine rechtliche Würdigung.
