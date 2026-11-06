import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '../api';
import { describePairingError, insights } from './api';
import { pairingChoices, pairingPhase } from './pairing';
import { pairingErrorText } from './text';
import type { DeviceList } from './types';

const err = (status: number, error: string, retryAfter?: number): Promise<ApiError> => {
	vi.stubGlobal(
		'fetch',
		vi.fn(
			async () =>
				new Response(JSON.stringify({ error }), {
					status,
					headers: retryAfter ? { 'Retry-After': String(retryAfter) } : {}
				})
		)
	);
	return insights.openPairing(5).then(
		() => {
			throw new Error('erwartet Fehler');
		},
		(e) => e as ApiError
	);
};
afterEach(() => vi.unstubAllGlobals());

describe('Datenschicht Kopplungsfenster', () => {
	it('oeffnet mit Minuten und schliesst per DELETE', async () => {
		const f = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>(
			async () =>
				new Response(JSON.stringify({ open: true, endsAt: '2026-11-06T14:05:00Z' }), {
					status: 200
				})
		);
		vi.stubGlobal('fetch', f);
		await expect(insights.openPairing(10)).resolves.toEqual({
			open: true,
			endsAt: '2026-11-06T14:05:00Z'
		});
		expect(f.mock.calls[0][0]).toBe('/dash/api/devices/pairing');
		expect(f.mock.calls[0][1]?.method).toBe('POST');
		expect(JSON.parse(String(f.mock.calls[0][1]?.body))).toEqual({ minutes: 10 });
		await insights.closePairing();
		expect(f.mock.calls[1][1]?.method).toBe('DELETE');
	});
});

describe('Fehlertexte Kopplungsfenster', () => {
	it('429 nennt die Wartezeit', async () => {
		const e = await err(429, 'rate_limited', 42);
		expect(describePairingError(e)).toBe(
			`${pairingErrorText.rate_limited} Erneut möglich in 42 s.`
		);
	});
	it('401 und 400 haben deutsche Texte', async () => {
		expect(describePairingError(await err(401, 'unauthorized'))).toMatch(/neu anmelden/);
		expect(describePairingError(await err(400, 'validation'))).toMatch(/1 bis 15 Minuten/);
	});
	it('unbekannte Codes fallen auf die allgemeinen Texte zurueck', async () => {
		expect(describePairingError(await err(503, 'data_unavailable'))).toMatch(/Datenbank/);
		expect(describePairingError(new Error('x'))).toBe('Unbekannter Fehler.');
	});
});

describe('Fixture devices.200 mit Kopplungsfenster (sobald vorhanden)', () => {
	const dir = resolve(
		dirname(fileURLToPath(import.meta.url)),
		'../../../../docs/fixtures/dashboard'
	);
	const files = existsSync(dir)
		? readdirSync(dir).filter((f) => /^devices\.[^.]+\.json$/.test(f))
		: [];
	for (const f of files) {
		it(`${f}: pairing passt zur Oberflaeche`, () => {
			const d = JSON.parse(readFileSync(resolve(dir, f), 'utf8')) as DeviceList;
			if (!d.pairing) return; // aeltere Fixture ohne Fenster
			expect(typeof d.pairing.open).toBe('boolean');
			expect(d.pairing.open ? typeof d.pairing.endsAt : d.pairing.endsAt).toBe(
				d.pairing.open ? 'string' : null
			);
			expect(pairingChoices(d.pairing.maxMinutes)).toContain(d.pairing.defaultMinutes);
			const now = d.pairing.endsAt ? Date.parse(d.pairing.endsAt) - 120_000 : Date.now();
			expect(pairingPhase(d.pairing, now).phase).toBe(d.pairing.open ? 'open' : 'closed');
		});
	}
});
