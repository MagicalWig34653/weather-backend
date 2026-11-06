import { describe, expect, it } from 'vitest';
import type { AuditEntry } from './api';
import { actorOf, applyFilter, clip, details, outcomeText, paginate, subject } from './audit';

const base: AuditEntry = {
	id: 1,
	at: '2026-11-06T09:00:00Z',
	action: 'set',
	configKey: null,
	oldValue: null,
	newValue: null,
	deviceRef: null,
	outcome: null
};
const mk = (o: Partial<AuditEntry>): AuditEntry => ({ ...base, ...o });
const NOW = Date.parse('2026-11-06T12:00:00Z');

describe('Filter', () => {
	const entries = [
		mk({ id: 1, at: '2026-11-06T11:00:00Z' }),
		mk({ id: 2, at: '2026-11-04T11:00:00Z', action: 'reset_cli' }),
		mk({ id: 3, at: '2026-10-10T11:00:00Z', action: 'login' })
	];
	it('filtert nach Zeitraum', () => {
		expect(applyFilter(entries, { period: 'all', actor: 'all' }, NOW)).toHaveLength(3);
		expect(applyFilter(entries, { period: '24h', actor: 'all' }, NOW).map((e) => e.id)).toEqual([
			1
		]);
		expect(applyFilter(entries, { period: '7d', actor: 'all' }, NOW).map((e) => e.id)).toEqual([
			1, 2
		]);
		expect(applyFilter(entries, { period: '30d', actor: 'all' }, NOW).map((e) => e.id)).toEqual([
			1, 2, 3
		]);
	});
	it('filtert nach Akteur', () => {
		expect(actorOf(entries[1])).toBe('cli');
		expect(applyFilter(entries, { period: 'all', actor: 'cli' }, NOW).map((e) => e.id)).toEqual([
			2
		]);
		expect(
			applyFilter(entries, { period: 'all', actor: 'operator' }, NOW).map((e) => e.id)
		).toEqual([1, 3]);
	});
});

describe('paginate', () => {
	const items = Array.from({ length: 60 }, (_, i) => i);
	it('teilt in Seiten', () => {
		const p = paginate(items, 2, 25);
		expect(p).toMatchObject({ page: 2, pages: 3, from: 26, to: 50, total: 60 });
		expect(p.items[0]).toBe(25);
		expect(paginate(items, 3, 25).items).toHaveLength(10);
	});
	it('begrenzt ungueltige Seiten und kommt mit leerer Liste zurecht', () => {
		expect(paginate(items, 99, 25).page).toBe(3);
		expect(paginate(items, -4, 25).page).toBe(1);
		expect(paginate([], 1, 25)).toMatchObject({ pages: 1, from: 0, to: 0, total: 0, items: [] });
	});
});

describe('Texte', () => {
	it('beschreibt Betreff je Aktion', () => {
		expect(subject(mk({ configKey: 'CACHE_MAX_MB', oldValue: '64', newValue: '128' }))).toBe(
			'CACHE_MAX_MB: 64 → 128'
		);
		expect(
			subject(mk({ action: 'device_action', deviceRef: '4be1c09a', outcome: 'test:delivered' }))
		).toBe('Gerät 4be1c09a, Testpush: zugestellt');
		expect(subject(mk({ action: 'restart', newValue: '5' }))).toBe('Generation 5');
		expect(subject(mk({ action: 'push_pause', newValue: 'true' }))).toBe('Versand pausiert');
		expect(subject(mk({ action: 'login' }))).toBe('–');
	});
	it('toleriert unbekannte Ergebnisse', () => {
		expect(outcomeText('seltsam')).toBe('seltsam');
		expect(outcomeText('neu:wasauchimmer')).toBe('neu: wasauchimmer');
		expect(outcomeText(null)).toBeNull();
	});
	it('kuerzt lange Werte', () => {
		expect(clip('x'.repeat(100), 10)).toBe('xxxxxxxxx…');
		expect(clip(null)).toBe('–');
	});
	it('listet in der Detailansicht nur vorhandene Felder', () => {
		const labels = details(mk({ configKey: 'K', newValue: 'v' })).map((d) => d.label);
		expect(labels).toEqual([
			'Nummer',
			'Zeitpunkt (UTC)',
			'Aktion',
			'Akteur',
			'Schlüssel',
			'Neuer Wert'
		]);
	});
});
