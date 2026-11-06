import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

const axe = async (page: Page) =>
	(
		await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze()
	).violations.map(
		(v) =>
			`${v.id}: ${v.nodes
				.map((n) => n.target.join(' '))
				.slice(0, 3)
				.join(' | ')}`
	);

const row = (page: Page, key: string) => page.locator('form', { has: page.locator(`#cfg-${key}`) });

test.describe('Konfiguration', () => {
	test('prüft Typ und Grenzen vor dem Speichern', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		const input = page.locator('#cfg-FETCH_WORKERS');
		const save = row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Speichern' });
		await expect(save).toBeDisabled();
		await input.fill('99');
		await expect(page.getByText('Erlaubt sind Werte 1 bis 8.')).toBeVisible();
		await expect(save).toBeDisabled();
		await input.fill('1,5');
		await expect(page.getByText('Ganze Zahl erwartet')).toBeVisible();
		await input.fill('4');
		await expect(save).toBeEnabled();
	});

	test('Änderung mit Bestätigung, Hinweis auf Neustart und Zurücksetzen', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await page.locator('#cfg-FETCH_WORKERS').fill('4');
		await row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Speichern' }).click();
		const dialog = page.getByRole('dialog');
		await expect(dialog).toContainText('FETCH_WORKERS');
		await expect(dialog).toContainText('2');
		await expect(dialog).toContainText('4');
		expect(await axe(page)).toEqual([]);
		await dialog.getByRole('button', { name: 'Speichern' }).click();
		await expect(
			page.getByRole('status').filter({ hasText: 'FETCH_WORKERS gespeichert' })
		).toBeVisible();
		await expect(
			row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Auf Standard' })
		).toBeEnabled();
		await row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Auf Standard' }).click();
		await expect(page.getByRole('dialog')).toContainText('Zurücksetzen');
		await page.getByRole('dialog').getByRole('button', { name: 'Zurücksetzen' }).click();
		await expect(page.locator('#cfg-FETCH_WORKERS')).toHaveValue('2');
	});

	test('Abbrechen ändert nichts', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await page.locator('#cfg-FETCH_WORKERS').fill('3');
		await row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Speichern' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Abbrechen' }).click();
		await expect(page.getByRole('dialog')).toBeHidden();
		await page.goto('/dash/protokoll?mock=auth');
		await expect(page.getByText('FETCH_WORKERS')).toHaveCount(0);
	});

	test('gesperrte Werte sind nur lesbar, Geheimnisse bleiben verborgen', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await expect(page.locator('#cfg-PUSH_ENABLED')).toHaveAttribute('readonly', '');
		await expect(page.locator('#cfg-APNS_KEY_FILE')).toHaveValue('');
		await expect(row(page, 'APNS_KEY_FILE').getByRole('button', { name: 'Speichern' })).toHaveCount(
			0
		);
	});

	test('Schwellen werden in Prozent erfasst und auf Reihenfolge geprüft', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await expect(page.locator('#thr-ERROR_RATE_5XX-y')).toHaveValue('0,5');
		await page.locator('#thr-ERROR_RATE_5XX-y').fill('3');
		await expect(
			page.getByText('Die Warnschwelle muss unter der kritischen Schwelle liegen.')
		).toBeVisible();
		await page.locator('#thr-ERROR_RATE_5XX-y').fill('1');
		const form = page.locator('form', { has: page.locator('#thr-ERROR_RATE_5XX-y') });
		await form.getByRole('button', { name: 'Speichern' }).click();
		await expect(page.getByRole('dialog')).toContainText('DASH_WARN_ERROR_RATE_5XX_YELLOW');
		await expect(page.getByRole('dialog')).toContainText('0,5 %');
		await page.getByRole('dialog').getByRole('button', { name: 'Speichern' }).click();
		await expect(page.getByRole('status').filter({ hasText: 'gespeichert' })).toBeVisible();
	});

	test('Neustart mit Bestätigung und Begrenzung', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await page.getByRole('button', { name: 'Dienst neu starten' }).click();
		const dialog = page.getByRole('dialog');
		await expect(dialog).toContainText('CACHE_MAX_MB');
		await dialog.getByRole('button', { name: 'Jetzt neu starten' }).click();
		await expect(page.getByRole('status').filter({ hasText: 'Neustart ausgelöst' })).toBeVisible();
		await expect(page.getByText('Neustart läuft')).toBeVisible();
	});

	test('Push-Pause braucht Bestätigung', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await page.getByRole('button', { name: 'Versand pausieren' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Pausieren' }).click();
		await expect(page.getByRole('button', { name: 'Versand fortsetzen' })).toBeVisible();
		await expect(page.getByText('Es wird derzeit nichts gesendet.')).toBeVisible();
	});

	test('zeigt Wartezeit bei 429', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth&mockstate=limited');
		await page.locator('#cfg-FETCH_WORKERS').fill('4');
		await row(page, 'FETCH_WORKERS').getByRole('button', { name: 'Speichern' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Speichern' }).click();
		await expect(page.getByRole('dialog').getByRole('alert')).toContainText(
			'Erneut möglich in 42 s'
		);
	});

	test('Suche und Filter', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth');
		await page.getByRole('searchbox').fill('cache_max');
		await expect(page.locator('#cfg-CACHE_MAX_MB')).toBeVisible();
		await expect(page.locator('#cfg-FETCH_WORKERS')).toHaveCount(0);
		await page.getByRole('searchbox').fill('zzz');
		await expect(page.getByText('Keine Einstellung passt zur Suche.')).toBeVisible();
	});

	test('Fehlerzustand mit Wiederholen', async ({ page }) => {
		await page.goto('/dash/konfiguration?mock=auth&mockstate=error');
		await expect(
			page.getByRole('alert').filter({ hasText: 'Daten konnten nicht geladen werden' })
		).toBeVisible();
		expect(await axe(page)).toEqual([]);
	});
});

test.describe('Protokoll', () => {
	test('Aktion filtern, blättern, Details ohne Geheimnisse', async ({ page }) => {
		await page.goto('/dash/protokoll?mock=auth');
		await expect(page.getByText('1 bis 25 von 66')).toBeVisible();
		await page.getByRole('button', { name: 'Ältere' }).click();
		await expect(page.getByText('Seite 2 von 3')).toBeVisible();
		await page.getByLabel('Aktion').selectOption('device_action');
		await expect(page.getByText('Seite 1 von 1')).toBeVisible();
		await expect(page.getByRole('cell', { name: 'Geräteaktion' }).first()).toBeVisible();
		await page
			.getByRole('button', { name: /^Details zu Eintrag/ })
			.first()
			.click();
		const dialog = page.getByRole('dialog');
		await expect(dialog).toContainText('Gerätebezug');
		await expect(dialog).toContainText('4be1c09a');
		await expect(dialog).not.toContainText(/token|secret/i);
		expect(await axe(page)).toEqual([]);
		await page.keyboard.press('Escape');
		await expect(dialog).toBeHidden();
	});

	test('Zeitraum und Akteur', async ({ page }) => {
		await page.goto('/dash/protokoll?mock=auth');
		await page.getByRole('radio', { name: 'Kommandozeile' }).click();
		await expect(page.getByText('1 bis 1 von 1')).toBeVisible();
		await page.getByRole('radio', { name: 'Letzte 24 Stunden' }).click();
		await expect(page.getByText('Kein Eintrag passt zu den Filtern.')).toBeVisible();
	});

	test('Leerer Zustand', async ({ page }) => {
		await page.goto('/dash/protokoll?mock=auth');
		await page.getByLabel('Aktion').selectOption('device_unpair');
		await expect(page.getByText('Keine Einträge zu dieser Aktion')).toBeVisible();
		expect(await axe(page)).toEqual([]);
	});
});

test.describe('Geräte', () => {
	test('prüft den Koppelcode und zeigt Serverfehler', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth');
		const code = page.getByLabel('Koppelcode aus der App');
		const label = page.getByLabel('Bezeichnung');
		const submit = page.getByRole('button', { name: 'Koppeln', exact: true });
		await code.fill('ABCD-EFGU');
		await label.fill('Test');
		await expect(submit).toBeDisabled();
		await code.fill('XXXX-XXXX');
		await expect(submit).toBeEnabled();
		await submit.click();
		await expect(page.getByRole('alert').filter({ hasText: 'Code unbekannt' })).toBeVisible();
	});

	test('fehlgeschlagener Auftrag nennt den Grund', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth&mockcmd=failed');
		await page.getByRole('button', { name: 'Testpush' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Testpush', exact: true }).click();
		await expect(
			page.getByRole('alert').filter({ hasText: 'Testpush: fehlgeschlagen' })
		).toBeVisible({ timeout: 15_000 });
		await expect(
			page.getByText('APNs-Umgebung des Geräts ist auf diesem Server nicht erlaubt').first()
		).toBeVisible();
	});

	test('nicht übernommener Auftrag und 429', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth&mockcmd=expired');
		await page.getByRole('button', { name: 'Testpush' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Testpush', exact: true }).click();
		await expect(page.getByRole('alert').filter({ hasText: 'nicht ausgeführt' })).toBeVisible({
			timeout: 15_000
		});
		await page.goto('/dash/geraete?mock=auth&mockstate=limited');
		await page.getByRole('button', { name: 'Testpush' }).click();
		await page.getByRole('dialog').getByRole('button', { name: 'Testpush', exact: true }).click();
		await expect(
			page.getByRole('alert').filter({ hasText: 'Aktion fehlgeschlagen' })
		).toContainText('Erneut möglich in 42 s');
	});

	test('Widerruf braucht Bestätigung', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth');
		await page.getByRole('button', { name: 'Widerrufen' }).click();
		await expect(page.getByRole('dialog')).toContainText('verschwindet aus dem Dashboard');
		await page.getByRole('dialog').getByRole('button', { name: 'Widerrufen' }).click();
		await expect(page.getByRole('status').filter({ hasText: 'Kopplung widerrufen' })).toBeVisible();
	});
});

test.describe('Kopplungsfenster', () => {
	const panel = (page: Page) => page.getByRole('region', { name: 'Kopplung freigeben' });

	test('freigeben, Dauer wählen, schließen; Fokus wandert mit', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth');
		await expect(panel(page).getByText('Geschlossen', { exact: true })).toBeVisible();
		await panel(page).getByRole('radio', { name: '10 Minuten' }).click();
		const open = panel(page).getByRole('button', { name: 'Kopplung freigeben (10 Min.)' });
		await open.click();
		await expect(panel(page).getByText('Offen', { exact: true })).toBeVisible();
		await expect(panel(page).locator('strong.tabular-nums')).toHaveText(/^(09:5\d|10:00)$/);
		const close = panel(page).getByRole('button', { name: 'Jetzt schließen' });
		await expect(close).toBeFocused();
		await expect(
			page.getByRole('status').filter({ hasText: 'Kopplung freigegeben' })
		).toBeVisible();
		await expect(page.getByRole('region', { name: 'Gerät koppeln' })).toHaveClass(/ring-2/);
		await close.click();
		await expect(panel(page).getByText('Geschlossen', { exact: true })).toBeVisible();
		await expect(
			page.getByRole('status').filter({ hasText: 'Kopplungsfenster geschlossen' })
		).toBeVisible();
		await expect(panel(page).getByRole('button', { name: /Kopplung freigeben \(/ })).toBeFocused();
	});

	test('Einlösen schließt das Fenster ohne Neuladen', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth&mockstate=pairopen');
		await expect(panel(page).getByText('Offen', { exact: true })).toBeVisible();
		await page.getByLabel('Koppelcode aus der App').fill('ABCD-EFGH');
		await page.getByLabel('Bezeichnung').fill('Zweites iPhone');
		await page.getByRole('button', { name: 'Koppeln', exact: true }).click();
		await expect(panel(page).getByText('Geschlossen', { exact: true })).toBeVisible();
		await expect(panel(page)).toContainText('Kopplungsfenster wurde geschlossen');
		await expect(page.getByRole('status').filter({ hasText: 'wurde geschlossen' })).toHaveCount(1);
	});

	test('läuft ab und schließt sich selbst', async ({ page }) => {
		test.setTimeout(90_000);
		await page.goto('/dash/geraete?mock=auth&mockstate=pairending');
		await expect(panel(page).getByText('Läuft ab')).toBeVisible({ timeout: 20_000 });
		await expect(panel(page).getByText('Geschlossen', { exact: true })).toBeVisible({
			timeout: 45_000
		});
		await expect(panel(page)).toContainText('Das Kopplungsfenster ist abgelaufen.');
	});

	test('429 nennt die Wartezeit', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth&mockstate=limited');
		await panel(page)
			.getByRole('button', { name: /Kopplung freigeben \(/ })
			.click();
		await expect(panel(page).getByRole('alert')).toContainText('Erneut möglich in 42 s');
		await expect(panel(page).getByText('Geschlossen', { exact: true })).toBeVisible();
	});
});

test.describe('Anmeldung', () => {
	for (const mock of ['setup', 'closed', 'login']) {
		test(`${mock}: erreichbar und ohne axe-Verstöße`, async ({ page }) => {
			await page.goto(`/dash/?mock=${mock}`);
			await expect(page.getByRole('button', { name: /Passkey|anmelden/i })).toBeVisible();
			expect(await axe(page)).toEqual([]);
		});
	}
	test('geschlossenes Einrichtungsfenster sperrt die Schaltfläche', async ({ page }) => {
		await page.goto('/dash/?mock=closed');
		await expect(page.getByText('Einrichtung geschlossen')).toBeVisible();
		await expect(page.getByRole('button', { name: /Passkey/ })).toBeDisabled();
	});
});

test('Dialog-Fokus bleibt im Dialog (Fokusfalle)', async ({ page }) => {
	await page.goto('/dash/konfiguration?mock=auth');
	await page.getByRole('button', { name: 'Dienst neu starten' }).click();
	const dialog = page.getByRole('dialog');
	for (let i = 0; i < 6; i++) {
		await page.keyboard.press('Tab');
		expect(await dialog.evaluate((d) => d.contains(document.activeElement))).toBe(true);
	}
});

test.describe('Aktualisierung', () => {
	test('ein einzelner Fehlschlag wird still wiederholt und nicht angezeigt', async ({ page }) => {
		await page.goto('/dash/?mock=auth&mockstate=flaky');
		await expect(
			page.getByRole('heading', { name: /Alles unauffällig|Befund/ }).first()
		).toBeVisible();
		await expect(page.getByRole('status').filter({ hasText: /^Veraltet:/ })).toHaveCount(0);
		await page.getByRole('button', { name: 'Aktualisieren', exact: true }).click();
		await expect(page.getByRole('status').filter({ hasText: /^Veraltet:/ })).toHaveCount(0);
		await expect(page.getByText('Daten konnten nicht geladen werden')).toHaveCount(0);
	});

	test('wiederholte Fehlschläge zeigen Veraltet mit konkretem Grund', async ({ page }) => {
		await page.goto('/dash/?mock=auth&mockstate=refreshfail');
		await expect(
			page.getByRole('heading', { name: /Alles unauffällig|Befund/ }).first()
		).toBeVisible();
		const refresh = page.getByRole('button', { name: 'Aktualisieren', exact: true });
		await refresh.click();
		await page.waitForTimeout(800);
		// Erster fehlgeschlagener Ladevorgang: noch kein Hinweis.
		await expect(page.getByRole('status').filter({ hasText: /^Veraltet:/ })).toHaveCount(0);
		await refresh.click();
		const notice = page.getByRole('status').filter({ hasText: 'Veraltet' });
		await expect(notice).toContainText('wiederholt fehlgeschlagen');
		await expect(notice).toContainText('nicht verfügbar (504)');
		expect(await axe(page)).toEqual([]);
	});
});

test.describe('Cache-Seite', () => {
	test('zeigt Inventar, Grund für Ausfall, Vorschau mit Slider und Auftragsstatus', async ({
		page
	}) => {
		await page.goto('/dash/cache?mock=auth');
		await expect(page.getByRole('heading', { name: 'Cache', level: 1 })).toBeVisible();
		const table = page.getByRole('region', { name: 'Cache-Inventar je Ebene' });
		await expect(table).toContainText('Luftdruck (Europa)');
		await expect(table).toContainText('Ausgefallen');
		await expect(page.getByText('Seit 15 h wurde nichts Neues veröffentlicht')).toBeVisible();
		// Vorschau: Bild mit Alt-Text, Slider und Pfeiltasten
		const img = page.getByRole('img', { name: /Niederschlagsradar, Bild vom/ });
		await expect(img).toBeVisible();
		const slider = page.getByRole('slider', { name: /Zeitpunkt wählen/ });
		const before = await slider.inputValue();
		await slider.focus();
		await page.keyboard.press('ArrowLeft');
		expect(Number(await slider.inputValue())).toBe(Number(before) - 1);
		await page.getByRole('button', { name: 'Neuester' }).click();
		expect(await slider.inputValue()).toBe(before);
		// Ebene neu abrufen: Auftrag läuft, endet mit Ergebnis
		await page.getByRole('button', { name: 'Niederschlagsradar neu abrufen' }).click();
		await expect(page.getByRole('status').filter({ hasText: 'Auftrag' }).first()).toBeVisible();
		await expect(
			page.getByRole('status').filter({ hasText: 'Niederschlagsradar: Abruf abgeschlossen' })
		).toBeVisible({ timeout: 15_000 });
	});

	test('fehlgeschlagener Abruf nennt den Grund', async ({ page }) => {
		await page.goto('/dash/cache?mock=auth');
		await page.getByRole('button', { name: 'Luftdruck (Europa) neu abrufen' }).click();
		await expect(page.getByText('Luftdruck (Europa): Abruf fehlgeschlagen')).toBeVisible({
			timeout: 15_000
		});
		await expect(page.getByText('Die Quelle (DWD/EUMETSAT) antwortet nicht').first()).toBeVisible();
	});

	test('Übersicht verlinkt den Luftdruck-Befund auf die Cache-Seite', async ({ page }) => {
		await page.goto('/dash/?mock=auth');
		await page.getByRole('link', { name: 'Zur Cache-Seite' }).first().click();
		await expect(page).toHaveURL(/\/dash\/cache\?layer=pressure/);
	});

	test('Leerzustand', async ({ page }) => {
		await page.goto('/dash/cache?mock=auth&mockstate=empty');
		await expect(page.getByText(/Keine Slots für/)).toBeVisible();
	});
});

test.describe('Geräte-Abos', () => {
	test('zeigt Abos mit verständlichen Zuständen', async ({ page }) => {
		await page.goto('/dash/geraete?mock=auth');
		await expect(page.getByRole('heading', { name: 'Abos dieses Geräts' }).first()).toBeVisible();
		await expect(page.getByText('Abo 1: Punkt').first()).toBeVisible();
		await expect(page.getByText('Benachrichtigt').first()).toBeVisible();
		await expect(page.getByText('Live Activity läuft').first()).toBeVisible();
	});
});
