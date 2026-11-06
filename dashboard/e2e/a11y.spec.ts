import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

const pages = [
	'',
	'betrieb',
	'traffic',
	'push',
	'abos',
	'geraete',
	'cache',
	'cache?mockstate=empty',
	'konfiguration',
	'protokoll',
	'_design'
];

for (const scheme of ['light', 'dark'] as const) {
	for (const [name, size] of [
		['desktop', { width: 1280, height: 900 }],
		['phone', { width: 390, height: 844 }]
	] as const) {
		test.describe(`${scheme} ${name}`, () => {
			test.use({ colorScheme: scheme, viewport: size });
			for (const p of pages) {
				test(`axe /${p}`, async ({ page }) => {
					await page.goto(`/dash/${p}${p.includes('?') ? '&' : '?'}mock=auth`);
					await page.waitForSelector('main h1');
					await page.waitForTimeout(700);
					const r = await new AxeBuilder({ page })
						.withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'])
						.analyze();
					expect(
						r.violations.map(
							(v) =>
								`${v.id}: ${v.nodes
									.map((n) => n.target.join(' '))
									.slice(0, 3)
									.join(' | ')}`
						)
					).toEqual([]);
					// Kein horizontaler Seitenscroll
					const overflow = await page.evaluate(
						() => document.documentElement.scrollWidth - window.innerWidth
					);
					expect(overflow).toBeLessThanOrEqual(0);
				});
			}
		});
	}
}

test('Zeitbereich steht in der URL und Tastatur bedient das Diagramm', async ({ page }) => {
	await page.goto('/dash/traffic?mock=auth');
	await page.getByRole('radio', { name: 'Letzte 7 Tage' }).first().click();
	await expect(page).toHaveURL(/range=7d/);
	const chart = page.getByRole('group', { name: /Anfragen/ }).first();
	await chart.focus();
	await page.keyboard.press('ArrowLeft');
	await expect(
		page
			.locator('[aria-live=polite]')
			.filter({ hasText: /Anfragen/ })
			.first()
	).toBeVisible();
	await page.getByRole('button', { name: 'Tabelle' }).first().click();
	await expect(page.getByRole('table').first()).toBeVisible();
});

test('Bestätigungsdialog und Toast', async ({ page }) => {
	await page.goto('/dash/geraete?mock=auth');
	await page.getByRole('button', { name: 'Testpush' }).click();
	await expect(page.getByRole('dialog')).toBeVisible();
	await page.getByRole('button', { name: 'Testpush', exact: true }).last().click();
	await expect(page.getByRole('status').filter({ hasText: 'Testpush: erledigt' })).toBeVisible({
		timeout: 10_000
	});
});

// Zustände: leer, Fehler, Teilausfall (Mock-Schalter) je Seite, hell/dunkel auf dem Telefon.
for (const state of ['empty', 'error', 'slice1'] as const) {
	test.describe(`Zustand ${state}`, () => {
		test.use({ viewport: { width: 390, height: 844 } });
		for (const p of [
			'',
			'betrieb',
			'traffic',
			'push',
			'abos',
			'geraete',
			'konfiguration',
			'protokoll'
		]) {
			test(`axe /${p} (${state})`, async ({ page }) => {
				await page.goto(`/dash/${p}?mock=auth&mockstate=${state}`);
				await page.waitForSelector('main h1');
				await page.waitForTimeout(700);
				const r = await new AxeBuilder({ page })
					.withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'])
					.analyze();
				expect(
					r.violations.map(
						(v) =>
							`${v.id}: ${v.nodes
								.map((n) => n.target.join(' '))
								.slice(0, 3)
								.join(' | ')}`
					)
				).toEqual([]);
			});
		}
	});
}

// Kopplungsfenster: offen und ablaufend, hell/dunkel, Desktop/Telefon.
for (const scheme of ['light', 'dark'] as const) {
	for (const [name, size] of [
		['desktop', { width: 1280, height: 900 }],
		['phone', { width: 390, height: 844 }]
	] as const) {
		test.describe(`Kopplungsfenster ${scheme} ${name}`, () => {
			test.use({ colorScheme: scheme, viewport: size });
			for (const state of ['pairopen', 'pairending', 'limited']) {
				test(`axe /geraete (${state})`, async ({ page }) => {
					await page.goto(`/dash/geraete?mock=auth&mockstate=${state}`);
					await page.waitForSelector('main h1');
					await page.waitForTimeout(700);
					if (state === 'limited')
						await page.getByRole('button', { name: /Kopplung freigeben \(/ }).click();
					const r = await new AxeBuilder({ page })
						.withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'])
						.analyze();
					expect(
						r.violations.map(
							(v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`
						)
					).toEqual([]);
					const overflow = await page.evaluate(
						() => document.documentElement.scrollWidth - window.innerWidth
					);
					expect(overflow).toBeLessThanOrEqual(0);
				});
			}
		});
	}
}

test('Traffic mit nur einer Stunde Daten: Einzelpunkt, Datenmenge noch nicht erfasst', async ({
	page
}) => {
	await page.goto('/dash/traffic?mock=auth&mockstate=sparse');
	await expect(page.getByText('noch nicht erfasst')).toBeVisible();
	// Der Einzelwert der Reihe wird als Punkt gezeichnet (keine leere Flaeche).
	await expect(page.locator('svg circle').first()).toBeVisible();
});

test('Traffic ohne Stundenzähler: Tagesansicht mit Hinweis statt Nullreihe', async ({ page }) => {
	await page.goto('/dash/traffic?mock=auth&mockstate=dayonly');
	await expect(page.getByText(/Stundenzähler noch nicht erfasst/)).toBeVisible();
	await expect(page.getByText('8.558').first()).toBeVisible();
});

// App-Icon folgt dem im UI gewählten Theme (.dark am <html>), nicht nur prefers-color-scheme.
test('App-Icon folgt dem gewählten Theme', async ({ page }) => {
	await page.emulateMedia({ colorScheme: 'light' });
	await page.goto('/dash/?mock=auth');
	await page.waitForSelector('main h1');
	const vis = (v: string) =>
		page.locator(`aside img[data-icon="${v}"], header img[data-icon="${v}"]`).first();
	await expect(vis('light')).toBeVisible();
	await expect(vis('dark')).toBeHidden();
	await page.evaluate(() => document.documentElement.classList.add('dark'));
	await expect(vis('dark')).toBeVisible();
	await expect(vis('light')).toBeHidden();
});
