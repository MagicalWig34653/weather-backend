// Nachbearbeitung des statischen Builds fuer die strikte CSP (Plan 6.4):
// 1. Der Routen-Ansager von SvelteKit (#svelte-announcer) traegt ein style-Attribut im Client-Code.
//    Es wird durch die gleichwertige Tailwind-Klasse sr-only ersetzt (Build bricht ab, falls SvelteKit
//    den Text aendert), damit style-src-attr nicht freigegeben werden muss.
// 2. // SvelteKit schreibt ein Inline-Startskript in index.html. Es wird in eine hashbenannte Datei
// ausgelagert, damit der Server `script-src 'self'` ohne 'unsafe-inline' und ohne Hash ausliefern kann.
// Danach wird geprueft, dass index.html weder Inline-Skripte noch style-Attribute enthaelt.
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../build/', import.meta.url));
const ANNOUNCER_STYLE =
	'style="position: absolute; left: 0; top: 0; clip: rect(0 0 0 0); clip-path: inset(50%); overflow: hidden; white-space: nowrap; width: 1px; height: 1px"';
let patched = 0;
for (const f of readdirSync(join(root, '_app/immutable'), { recursive: true })) {
	if (!f.endsWith('.js')) continue;
	const path = join(root, '_app/immutable', f);
	const src = readFileSync(path, 'utf8');
	if (src.includes(ANNOUNCER_STYLE)) {
		writeFileSync(path, src.replaceAll(ANNOUNCER_STYLE, 'class="sr-only"'));
		patched++;
	}
}
if (patched === 0) throw new Error('Routen-Ansager-Stil nicht gefunden (SvelteKit geaendert?).');

const indexPath = join(root, 'index.html');
let html = readFileSync(indexPath, 'utf8');

const inline = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)];
if (inline.length !== 1) {
	throw new Error(`Erwartet genau ein Inline-Startskript, gefunden: ${inline.length}`);
}
const code = inline[0][1].trim() + '\n';
const hash = createHash('sha256').update(code).digest('hex').slice(0, 10);
const base = html.match(/base:\s*"([^"]*)"/)?.[1] ?? '';
const file = `_app/immutable/boot.${hash}.js`;
writeFileSync(join(root, file), code);
html = html.replace(inline[0][0], `<script src="${base}/${file}"></script>`);
writeFileSync(indexPath, html);

const remaining = [...html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>/g)];
if (remaining.length > 0) throw new Error('index.html enthaelt noch Inline-Skripte.');
if (/\sstyle\s*=/.test(html)) throw new Error('index.html enthaelt style-Attribute.');
if (/<style[\s>]/.test(html)) throw new Error('index.html enthaelt Inline-Style-Elemente.');
if (/https?:\/\//.test(html.replace(/<!doctype[^>]*>/i, ''))) {
	throw new Error('index.html verweist auf externe Adressen.');
}
console.log(`Startskript ausgelagert: ${file}`);

// Produktionsbuild ohne Mock und Design-Vorschau (Plan 5: /dash/_design nur Dev/Mock).
// Die Marker stammen aus dem Mock-Server, dem Mock-Banner und der Vorschauseite.
const forbidden = [
	'Mock-Modus',
	'Mock-Daten',
	'mock-csrf-token',
	'db.example.internal',
	'createMockFetch',
	'Vorschau der Tokens und Bausteine'
];
const leaks = [];
for (const f of readdirSync(root, { recursive: true })) {
	if (!/\.(js|html|css|json|txt)$/.test(f)) continue;
	if (/mock/i.test(f) || /(^|[\\/])_design/.test(f)) leaks.push(`Datei ${f}`);
	const text = readFileSync(join(root, f), 'utf8');
	for (const m of forbidden) if (text.includes(m)) leaks.push(`${m} in ${f}`);
}
if (leaks.length > 0) {
	throw new Error(`Mock- oder Vorschau-Code im Produktionsbuild: ${leaks.join('; ')}`);
}
console.log('Produktionsbuild enthaelt weder Mock noch Design-Vorschau.');
