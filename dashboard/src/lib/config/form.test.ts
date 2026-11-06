import { describe, expect, it } from 'vitest';
import type { ConfigEntry } from '../api';
import {
	boundsText,
	canReset,
	draftOf,
	formatValue,
	groupEntries,
	isDirty,
	parseDraft,
	validateValue,
	valuesEqual
} from './form';

function e(over: Partial<ConfigEntry> = {}): ConfigEntry {
	return {
		key: 'K',
		group: 'G',
		type: 'int',
		default: 64,
		min: 8,
		max: 1024,
		unit: 'MB',
		description: 'Beschreibung',
		apply: 'live',
		source: 'default',
		locked: false,
		value: 64,
		restartPending: false,
		...over
	};
}

describe('parseDraft', () => {
	it('liest ganze Zahlen und prueft Grenzen', () => {
		expect(parseDraft(e(), ' 128 ')).toEqual({ ok: true, value: 128 });
		expect(parseDraft(e(), '7')).toMatchObject({ ok: false });
		expect(parseDraft(e(), '1025')).toMatchObject({ ok: false });
		expect(parseDraft(e(), '8')).toEqual({ ok: true, value: 8 });
		expect(parseDraft(e(), '1024')).toEqual({ ok: true, value: 1024 });
	});
	it.each(['', '  ', '1,5', '1.5', 'abc', '12abc', '1e3', '--1'])('lehnt %j fuer int ab', (t) => {
		expect(parseDraft(e(), t).ok).toBe(false);
	});
	it('liest Dezimalzahlen mit Komma oder Punkt', () => {
		const d = e({ type: 'double', min: 0, max: 1, unit: null, default: 0.5, value: 0.5 });
		expect(parseDraft(d, '0,25')).toEqual({ ok: true, value: 0.25 });
		expect(parseDraft(d, '.5')).toEqual({ ok: true, value: 0.5 });
		expect(parseDraft(d, '1,01')).toMatchObject({ ok: false });
		expect(parseDraft(d, 'NaN').ok).toBe(false);
		expect(parseDraft(d, 'Infinity').ok).toBe(false);
		expect(parseDraft(d, '').ok).toBe(false);
	});
	it('liest Schalter', () => {
		const b = e({ type: 'bool', min: null, max: null, value: false });
		expect(parseDraft(b, true)).toEqual({ ok: true, value: true });
		expect(parseDraft(b, false)).toEqual({ ok: true, value: false });
	});
	it('liest Listen: trimmt, lehnt Leere und Doppelte ab', () => {
		const l = e({ type: 'list', min: null, max: null, value: ['radar'] });
		expect(parseDraft(l, 'radar, pressure ;lightning')).toEqual({
			ok: true,
			value: ['radar', 'pressure', 'lightning']
		});
		expect(parseDraft(l, '')).toEqual({ ok: true, value: [] });
		expect(parseDraft(l, 'radar,,pressure').ok).toBe(false);
		expect(parseDraft(l, 'radar, radar').ok).toBe(false);
	});
	it('prueft Auswahl nur, wenn der Server Werte nennt', () => {
		const withChoices = e({ type: 'enum', choices: ['a', 'b'], value: 'a', min: null, max: null });
		expect(parseDraft(withChoices, 'b')).toEqual({ ok: true, value: 'b' });
		expect(parseDraft(withChoices, 'c')).toMatchObject({ ok: false });
		const open = e({ type: 'enum', value: 'a', min: null, max: null });
		expect(parseDraft(open, 'frei')).toEqual({ ok: true, value: 'frei' });
	});
	it('lehnt Steuerzeichen in Text ab und behandelt unbekannte Typen als Text', () => {
		const s = e({ type: 'string', min: null, max: null, value: 'x' });
		expect(parseDraft(s, 'a\u0000b').ok).toBe(false);
		expect(parseDraft(e({ type: 'neu', min: null, max: null, value: 'x' }), ' ok ')).toEqual({
			ok: true,
			value: 'ok'
		});
	});
});

describe('validateValue (typisierte Werte, wie der Server)', () => {
	it('lehnt falsche Typen ab', () => {
		expect(validateValue(e(), '5').ok).toBe(false);
		expect(validateValue(e(), 5.5).ok).toBe(false);
		expect(validateValue(e({ type: 'bool' }), 1).ok).toBe(false);
		expect(validateValue(e({ type: 'double' }), Number.NaN).ok).toBe(false);
		expect(validateValue(e({ type: 'list' }), 'a').ok).toBe(false);
		expect(validateValue(e({ type: 'string' }), 5).ok).toBe(false);
	});
	it('kennt offene Grenzen', () => {
		const lo = e({ min: 3, max: null });
		expect(validateValue(lo, 1000).ok).toBe(true);
		expect(validateValue(lo, 2).ok).toBe(false);
		expect(boundsText(lo)).toBe('mindestens 3 MB');
		expect(boundsText(e({ min: null, max: 9 }))).toBe('höchstens 9 MB');
		expect(boundsText(e({ min: null, max: null }))).toBeNull();
		expect(boundsText(e({ type: 'string' }))).toBeNull();
	});
});

describe('Anzeige und Vergleich', () => {
	it('formatiert Werte deutsch', () => {
		expect(formatValue(e(), 1024)).toBe('1024 MB');
		expect(formatValue(e({ type: 'double', unit: null }), 0.005)).toBe('0,005');
		expect(formatValue(e({ type: 'bool', unit: null }), true)).toBe('Ein');
		expect(formatValue(e({ type: 'list', unit: null }), ['a', 'b'])).toBe('a, b');
		expect(formatValue(e({ type: 'list', unit: null }), [])).toBe('(leer)');
		expect(formatValue(e({ type: 'string', unit: null }), '')).toBe('(leer)');
		expect(formatValue(e(), null)).toBe('–');
	});
	it('erzeugt den Entwurf aus dem Wert', () => {
		expect(draftOf(e({ value: 128 }))).toBe('128');
		expect(draftOf(e({ type: 'double', value: 0.25 }))).toBe('0,25');
		expect(draftOf(e({ type: 'bool', value: true }))).toBe(true);
		expect(draftOf(e({ type: 'list', value: ['a', 'b'] }))).toBe('a, b');
		expect(draftOf(e({ value: null }))).toBe('');
	});
	it('vergleicht Werte und erkennt Aenderungen', () => {
		expect(valuesEqual(['a'], ['a'])).toBe(true);
		expect(valuesEqual(['a'], ['b'])).toBe(false);
		expect(valuesEqual(1, 1)).toBe(true);
		expect(isDirty(e({ value: 64 }), '64')).toBe(false);
		expect(isDirty(e({ value: 64 }), '65')).toBe(true);
		expect(isDirty(e({ value: 64 }), 'x')).toBe(true);
	});
	it('erlaubt Zuruecksetzen nur bei ungesperrtem Dashboard-Wert', () => {
		expect(canReset(e({ source: 'dashboard' }))).toBe(true);
		expect(canReset(e({ source: 'default' }))).toBe(false);
		expect(canReset(e({ source: 'dashboard', locked: true }))).toBe(false);
	});
});

describe('groupEntries', () => {
	const all = [
		e({ key: 'A', group: 'X', description: 'alpha' }),
		e({ key: 'B', group: 'Y', description: 'beta', source: 'dashboard' }),
		e({ key: 'C', group: 'X', description: 'gamma', source: 'dashboard' })
	];
	it('gruppiert in Reihenfolge des ersten Auftretens', () => {
		expect(groupEntries(all).map((g) => [g.name, g.entries.map((x) => x.key)])).toEqual([
			['X', ['A', 'C']],
			['Y', ['B']]
		]);
	});
	it('filtert nach Suche (Schluessel, Beschreibung) und Dashboard-Werten', () => {
		expect(
			groupEntries(all, { query: 'BETA' }).flatMap((g) => g.entries.map((x) => x.key))
		).toEqual(['B']);
		expect(
			groupEntries(all, { onlyChanged: true }).flatMap((g) => g.entries.map((x) => x.key))
		).toEqual(['B', 'C']);
		expect(groupEntries(all, { query: 'nichts' })).toEqual([]);
	});
});
