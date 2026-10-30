// Statischer Generator fuer GitHub Pages. Kuratierte Seiten liegen in content/,
// docs/data-contract.md und Abschnitte aus README.md werden beim Build eingebunden.
// Aufruf: npm ci && node build.mjs   (Ausgabe: dist/, flach, nur relative Links)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..');
const out = path.join(here, 'dist');
const GH = 'https://github.com/MagicalWig34653/weather-backend';
const read = (p) => fs.readFileSync(p, 'utf8');
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const slugify = (s) =>
  s.toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss')
    .replace(/<[^>]+>/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'abschnitt';

const readme = read(path.join(repo, 'README.md'));
const readmeSection = (name) => {
  const m = readme.match(new RegExp(`^### ${name}.*?$([\\s\\S]*?)(?=^##+ |(?![\\s\\S]))`, 'm'));
  return m ? m[1].trim() : '';
};

// slug -> {title, group, raw, src}
const pages = [];
const add = (slug, group, file, opts = {}) => {
  const raw = opts.text ?? read(file);
  const m = raw.match(/^#\s+(.+)$/m);
  pages.push({ slug, group, raw, src: opts.src, title: opts.title ?? (m ? m[1].trim() : slug) });
};
const c = (f) => path.join(here, 'content', f);

add('index.html', 'Einstieg', c('index.md'), { title: 'Start' });
add('architektur.html', 'Einstieg', c('architektur.md'));
add('installation.html', 'Betrieb', c('installation.md'));
add('betrieb.html', 'Betrieb', c('betrieb.md'));
add('api.html', 'Referenz', c('api.md'), { title: 'API-Referenz' });
const dev = read(c('entwicklung.md')).replace('{{BUILD}}', readmeSection('Entwicklung und Tests'));
add('entwicklung.html', 'Referenz', null, { text: dev, title: 'Entwicklung' });
add('roadmap.html', 'Referenz', c('roadmap.md'));

const bySource = new Map(pages.filter((p) => p.src).map((p) => [path.basename(p.src), p.slug]));
const groups = ['Einstieg', 'Betrieb', 'Referenz'];

function marked() {
  const toc = [];
  const m = new Marked({ gfm: true });
  m.use({
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const id = slugify(text);
        if (depth === 2 || depth === 3) toc.push({ depth, id, text: text.replace(/<[^>]+>/g, '') });
        return `<h${depth} id="${id}">${text}</h${depth}>\n`;
      },
      link({ href, title, tokens }) {
        const text = this.parser.parseInline(tokens);
        let h = href;
        if (!/^(https?:|mailto:|#)/.test(h)) {
          const [file, hash] = h.split('#');
          const base = path.basename(file);
          if (bySource.has(base)) h = bySource.get(base) + (hash ? '#' + hash : '');
          else if (/\.md$|\/$|^\.\.?\//.test(file)) {
            // Nicht veroeffentlichte Repo-Datei: auf GitHub verweisen (relativ zu docs/).
            const rel = file.replace(/^\.\//, '');
            h = `${GH}/blob/main/${rel.startsWith('docs/') || rel.startsWith('../') ? rel.replace('../', '') : 'docs/' + rel}`;
          }
        }
        const ext = /^https?:/.test(h) ? ' rel="noopener"' : '';
        return `<a href="${esc(h)}"${title ? ` title="${esc(title)}"` : ''}${ext}>${text}</a>`;
      },
      table(token) {
        const head = token.header.map((h) => `<th>${this.parser.parseInline(h.tokens)}</th>`).join('');
        const rows = token.rows.map((r) => `<tr>${r.map((x) => `<td>${this.parser.parseInline(x.tokens)}</td>`).join('')}</tr>`).join('');
        return `<div class="tablewrap"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>`;
      },
    },
  });
  return { m, toc };
}

const themeScript = `(function(){try{var t=localStorage.getItem('theme');if(t)document.documentElement.dataset.theme=t}catch(e){}})()`;
const uiScript = `(function(){var r=document.documentElement,b=document.getElementById('theme');
function cur(){return r.dataset.theme||(matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light')}
function label(){b.textContent=cur()==='dark'?'Hell':'Dunkel'}
b.addEventListener('click',function(){var n=cur()==='dark'?'light':'dark';r.dataset.theme=n;try{localStorage.setItem('theme',n)}catch(e){}label()});label();
var sd=document.querySelector('.sided');if(sd&&matchMedia('(max-width:820px)').matches)sd.open=false;
var m=document.getElementById('menu'),n=document.getElementById('nav');
m.addEventListener('click',function(){var o=n.classList.toggle('open');m.setAttribute('aria-expanded',o)});})();`;

function layout(page, body, toc) {
  const cur = (s) => (page.slug === s ? ' aria-current="page"' : '');
  const top = [['index.html', 'Start'], ['architektur.html', 'Architektur'], ['installation.html', 'Installation'], ['betrieb.html', 'Betrieb'], ['api.html', 'API'], ['entwicklung.html', 'Entwicklung']]
    .map(([s, t]) => `<a href="${s}"${cur(s)}>${t}</a>`).join('');
  const side = groups.map((g) => `<h2>${g}</h2><ul>${pages.filter((p) => p.group === g)
    .map((p) => `<li><a href="${p.slug}"${cur(p.slug)}>${esc(p.title)}</a></li>`).join('')}</ul>`).join('');
  const tocHtml = toc.length > 3 ? `<details class="toc"><summary>Auf dieser Seite</summary><ul>${toc.map((t) => `<li class="d${t.depth}"><a href="#${t.id}">${t.text}</a></li>`).join('')}</ul></details>` : '';
  const srcLink = page.src ? `<p class="srclink">Quelle: <a href="${GH}/blob/main/${page.src}" rel="noopener"><code>${page.src}</code></a> (wird beim Build eingebunden)</p>` : '';
  return `<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(page.title)} – ShowerNow</title>
<meta name="description" content="ShowerNow Radar-Cache: Dokumentation und Installationsanleitung für das Backend (Swift/Vapor, MariaDB, Docker Swarm).">
<script>${themeScript}</script><link rel="stylesheet" href="style.css"></head>
<body><a class="skip" href="#main">Zum Inhalt</a>
<header class="top"><div class="bar">
<a class="brand" href="index.html"><span class="logo" aria-hidden="true">S</span>ShowerNow Backend</a>
<button id="menu" class="btn menu" aria-expanded="false" aria-controls="nav">Menü</button>
<nav id="nav" class="nav" aria-label="Hauptnavigation">${top}<a href="${GH}" rel="noopener">GitHub</a></nav>
<button id="theme" class="btn" type="button">Dunkel</button>
</div></header>
<div class="page with-side"><details class="sided" open><summary>Dokumentation</summary><nav class="side" aria-label="Dokumentation">${side}</nav></details>
<main id="main" class="doc">${tocHtml}${body}${srcLink}</main></div>
<footer class="foot"><div class="bar">ShowerNow Radar-Cache ist ein früher Betriebsstand. Diese Seite wird beim Build aus dem Repository erzeugt und enthält keine Zugangsdaten und keine Nutzerdaten. Quelle: Deutscher Wetterdienst (Daten verändert dargestellt). <a href="${GH}" rel="noopener">Quellcode</a></div></footer>
<script>${uiScript}</script></body></html>`;
}

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
fs.copyFileSync(path.join(here, 'style.css'), path.join(out, 'style.css'));
fs.writeFileSync(path.join(out, '.nojekyll'), '');
for (const p of pages) {
  const { m, toc } = marked();
  const html = m.parse(p.raw);
  fs.writeFileSync(path.join(out, p.slug), layout(p, html, toc));
}
fs.writeFileSync(path.join(out, '404.html'), layout({ slug: '404.html', title: 'Nicht gefunden', group: '' }, '<h1>Seite nicht gefunden</h1><p><a href="index.html">Zur Startseite</a></p>', []));
console.log(`built ${pages.length} pages -> ${path.relative(repo, out)}`);
