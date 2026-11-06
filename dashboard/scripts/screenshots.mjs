// Screenshots des Mock-Dashboards (hell/dunkel, Desktop/Tablet/Telefon). Voraussetzung: `npm run dev:mock -- --port 5199`.
// Aufruf: node scripts/screenshots.mjs <Ausgabeordner> [Seiten,kommagetrennt] [Zustand: normal|empty|error|slow]
import { chromium } from '@playwright/test';
import { mkdir } from 'node:fs/promises';

const out = process.argv[2] ?? 'screenshots';
const pages = (
	process.argv[3] ?? ',betrieb,traffic,push,abos,geraete,konfiguration,protokoll'
).split(',');
const state = process.argv[4] ?? 'normal';
const base = process.env.DASH_URL ?? 'http://localhost:5199/dash';
const sizes = { desktop: [1280, 900], tablet: [768, 1024], phone: [390, 844] };
const themes = (process.env.THEMES ?? 'light,dark').split(',');
const only = (process.env.SIZES ?? Object.keys(sizes).join(',')).split(',');

await mkdir(out, { recursive: true });
const browser = await chromium.launch();
for (const theme of themes) {
	for (const name of only) {
		const [width, height] = sizes[name];
		const ctx = await browser.newContext({
			viewport: { width, height },
			colorScheme: theme,
			deviceScaleFactor: 1
		});
		for (const p of pages) {
			const page = await ctx.newPage();
			const qs = new URLSearchParams({ mock: 'auth' });
			if (state !== 'normal') qs.set('mockstate', state);
			if (process.env.RANGE) qs.set('range', process.env.RANGE);
			await page.goto(`${base}/${p}?${qs}`);
			await page.waitForSelector('main', { timeout: 15000 });
			await page.waitForTimeout(state === 'slow' ? 800 : 1200);
			await page.screenshot({
				path: `${out}/${p || 'uebersicht'}-${name}-${theme}.png`,
				fullPage: process.env.FULL !== '0'
			});
			await page.close();
		}
		await ctx.close();
	}
}
await browser.close();
