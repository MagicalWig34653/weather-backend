# BoringSSL in swift-nio-ssl: Lizenzlage der Dateiköpfe (Stand 21. November 2026)

swift-nio-ssl liefert BoringSSL als Quelltext mit (`Sources/CNIOBoringSSL`, Namensraum `CNIOBoringSSL`). Die unveränderte `NOTICE.txt` von swift-nio-ssl (`third-party-licenses/swift-nio-ssl/NOTICE.txt`) nennt BoringSSL „Combination ISC and OpenSSL license“ und verweist auf die LICENSE des BoringSSL-Projekts. Der Upstream-Text wurde nicht verändert. Dieses Dokument hält zusätzlich fest, was die Quelldateien der hier verwendeten Version selbst tragen.

**Quelle und Revision:** swift-nio-ssl 2.37.6 (Commit `15e0b9e495786807272dd4891fa4bac76aa43034`), darin BoringSSL Revision `8eb25be6fa18d475291122887a7bccd3762ff236` (`Sources/CNIOBoringSSL/hash.txt`). Die Zahlen unten stammen aus einer Zeichenkettensuche über diese Checkouts (`grep` auf den Kopftext), nicht aus einem Lizenz-Scanner.

| Version | BoringSSL-Revision | Dateien mit „OpenSSL license“-Kopf | Dateien mit Apache-2.0-Kopf |
| --- | --- | --- | --- |
| swift-nio-ssl 2.37.5 (früherer Pin) | `817ab07e` | 323 | nicht erhoben |
| swift-nio-ssl 2.37.6 (aktueller Pin) | `8eb25be6` | 0 | 534 |

Weitere Befunde zu 2.37.6 (`CNIOBoringSSL`, 668 Dateien):

- Der Kopf „Licensed under the Apache License, Version 2.0“ steht in 534 Dateien; ISC-Köpfe kommen nicht vor.
- In 322 dieser Dateien steht zusätzlich eine Copyright-Zeile „The OpenSSL Project Authors“, in 206 eine mit Google/„The BoringSSL Authors“ (Überschneidungen möglich); der Lizenztext ist dort der Apache-2.0-Kopf.
- Ohne Apache-2.0-Kopf sind 134 Dateien: 112 Assembler-Dateien (`*.S`, davon 107 mit dem Vermerk „generated from a similarly-named Perl script“) und 22 weitere Dateien (darunter 14 unter `third_party/fiat/`, `hash.txt`, Modulmap, einige `*_known_values.inc`; ohne diesen Kopf). Diese Dateien wurden nicht einzeln gewürdigt.
- Die Bezeichner `SSLeay`/`RAND_SSLeay` (6 Dateien) sind API-Kompatibilitätsnamen, kein Lizenztext.
- swift-crypto 3.15.1 (CCryptoBoringSSL, Revision `0226f304`): 491 Dateien mit Apache-2.0-Kopf, 0 mit „OpenSSL license“-Kopf.

**Upstream-LICENSE der gepinnten Revision:** Der SwiftPM-Checkout von swift-nio-ssl 2.37.6 enthält keine BoringSSL-LICENSE-Datei (nur `LICENSE.txt` und `NOTICE.txt` von swift-nio-ssl). Deshalb liegt der unveränderte Text der `LICENSE` aus dem BoringSSL-Upstream bei Revision `8eb25be6fa18d475291122887a7bccd3762ff236` in [`third-party/boringssl/LICENSE`](third-party/boringssl/LICENSE) (SHA-256 `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f`, Herkunft und Abrufdatum in `third-party/boringssl/SOURCE.txt`), im Image unter `/licenses/boringssl/`. Inhalt dieser Datei: der Apache-License-2.0-Text sowie ein Abschnitt „Licenses for support code“ (BSD-3-Clause-Text der Go Authors für Teile der TLS-Testsuite, die laut Upstream nicht in BoringSSL einkompiliert sind). Ein ISC- oder „OpenSSL license“-Text kommt in dieser LICENSE nicht vor. Die Copyright-Zeilen der einzelnen Quelldateien (z. B. „The OpenSSL Project Authors“, „Google“/„The BoringSSL Authors“) stehen in den Quelldateien selbst (SwiftPM-Checkout) und sind nicht zusätzlich ins Image kopiert.

Das ist eine Beschreibung des Dateibestands, keine rechtliche Würdigung und keine Aussage, dass der Upstream-Hinweistext berichtigt wurde oder werden muss. Die Zuordnung veröffentlichter Images zu 2.37.5/2.37.6 steht in `docs/status.md`.
