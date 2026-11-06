/**
 * Formularlogik des Konfigurationsregisters: Entwurf (Text/Schalter) <-> typisierter Wert,
 * Typ- und Grenzenpruefung (spiegelt die Server-Pruefung, ersetzt sie nicht), Anzeige, Gruppierung.
 */
import type { ConfigApply, ConfigEntry, ConfigSource, ConfigValue } from '../api';

export type Parsed = { ok: true; value: ConfigValue } | { ok: false; error: string };

const nf = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 6, useGrouping: false });
const INT = /^[+-]?\d+$/;
const DECIMAL = /^[+-]?(\d+([.,]\d*)?|[.,]\d+)$/;

export const isBool = (e: ConfigEntry) => e.type === 'bool';
export const isList = (e: ConfigEntry) => e.type === 'list';
export const isEnum = (e: ConfigEntry) => e.type === 'enum';
export const isNumeric = (e: ConfigEntry) => e.type === 'int' || e.type === 'double';

/** Ein Wert kann nicht angezeigt werden: Geheimnis oder nur per Umgebungsvariable (Server liefert null). */
export const isHidden = (e: ConfigEntry) => e.value === null;

/** "von 8 bis 1.024 MB" bzw. null ohne Grenzen. */
export function boundsText(e: ConfigEntry): string | null {
	if (!isNumeric(e) || (e.min === null && e.max === null)) return null;
	const u = e.unit ? ` ${e.unit}` : '';
	if (e.min !== null && e.max !== null) return `${nf.format(e.min)} bis ${nf.format(e.max)}${u}`;
	return e.min !== null
		? `mindestens ${nf.format(e.min)}${u}`
		: `höchstens ${nf.format(e.max!)}${u}`;
}

/** Anzeigetext eines Werts (de-DE-Zahlen, Listen kommagetrennt, Wahrheitswerte als Ein/Aus). */
export function formatValue(e: ConfigEntry, v: ConfigValue = e.value): string {
	if (v === null) return '–';
	if (Array.isArray(v)) return v.length ? v.join(', ') : '(leer)';
	if (typeof v === 'boolean') return v ? 'Ein' : 'Aus';
	if (typeof v === 'number') return nf.format(v) + (e.unit ? ` ${e.unit}` : '');
	return v === '' ? '(leer)' : v;
}

/** Ausgangswert fuer das Eingabefeld (Text) bzw. den Schalter (Wahrheitswert). */
export function draftOf(e: ConfigEntry, v: ConfigValue = e.value): string | boolean {
	if (isBool(e)) return v === true;
	if (v === null) return '';
	if (Array.isArray(v)) return v.join(', ');
	return typeof v === 'number' ? nf.format(v) : String(v);
}

function range(e: ConfigEntry, n: number): string | null {
	if ((e.min !== null && n < e.min) || (e.max !== null && n > e.max))
		return `Erlaubt sind Werte ${boundsText(e)}.`;
	return null;
}

/** Prueft einen bereits typisierten Wert gegen Typ und Grenzen (wie der Server). */
export function validateValue(e: ConfigEntry, v: ConfigValue): Parsed {
	const bad = (error: string): Parsed => ({ ok: false, error });
	switch (e.type) {
		case 'bool':
			return typeof v === 'boolean' ? { ok: true, value: v } : bad('Ein oder Aus erwartet.');
		case 'int': {
			if (typeof v !== 'number' || !Number.isSafeInteger(v)) return bad('Ganze Zahl erwartet.');
			const r = range(e, v);
			return r ? bad(r) : { ok: true, value: v };
		}
		case 'double': {
			if (typeof v !== 'number' || !Number.isFinite(v)) return bad('Zahl erwartet.');
			const r = range(e, v);
			return r ? bad(r) : { ok: true, value: v };
		}
		case 'list': {
			if (!Array.isArray(v)) return bad('Liste erwartet.');
			if (v.some((x) => typeof x !== 'string' || x === '' || /[,\p{Cc}]/u.test(x)))
				return bad('Einträge dürfen nicht leer sein und kein Komma enthalten.');
			if (new Set(v).size !== v.length) return bad('Einträge dürfen sich nicht wiederholen.');
			return { ok: true, value: v };
		}
		default: {
			// string, enum und unbekannte Typen
			if (typeof v !== 'string') return bad('Text erwartet.');
			if (/\p{Cc}/u.test(v)) return bad('Steuerzeichen sind nicht erlaubt.');
			if (e.type === 'enum' && e.choices?.length && !e.choices.includes(v))
				return bad(`Erlaubt sind: ${e.choices.join(', ')}.`);
			return { ok: true, value: v };
		}
	}
}

/** Wandelt die Eingabe des Formulars in einen typisierten Wert und prueft ihn. */
export function parseDraft(e: ConfigEntry, draft: string | boolean): Parsed {
	if (isBool(e)) return validateValue(e, draft === true);
	const text = String(draft).trim();
	switch (e.type) {
		case 'int': {
			if (text === '') return { ok: false, error: 'Bitte eine ganze Zahl eingeben.' };
			if (!INT.test(text)) return { ok: false, error: 'Ganze Zahl erwartet (ohne Komma).' };
			return validateValue(e, Number(text));
		}
		case 'double': {
			if (text === '') return { ok: false, error: 'Bitte eine Zahl eingeben.' };
			if (!DECIMAL.test(text)) return { ok: false, error: 'Zahl erwartet, z. B. 0,5.' };
			return validateValue(e, Number(text.replace(',', '.')));
		}
		case 'list':
			return validateValue(e, text === '' ? [] : text.split(/[,;\n]/).map((s) => s.trim()));
		default:
			return validateValue(e, text);
	}
}

export function valuesEqual(a: ConfigValue, b: ConfigValue): boolean {
	if (Array.isArray(a) && Array.isArray(b))
		return a.length === b.length && a.every((x, i) => x === b[i]);
	return a === b;
}

/** Entwurf weicht vom aktuellen Wert ab (oder ist ungueltig). */
export function isDirty(e: ConfigEntry, draft: string | boolean): boolean {
	const p = parseDraft(e, draft);
	return !p.ok || !valuesEqual(p.value, e.value);
}

export const sourceLabel: Record<ConfigSource, string> = {
	env: 'Umgebungsvariable',
	dashboard: 'Dashboard-Wert',
	default: 'Standard'
};
export const applyLabel: Record<ConfigApply, string> = {
	live: 'wirkt nach höchstens 30 s',
	restart: 'wirkt erst nach Neustart'
};

export const typeLabel: Record<string, string> = {
	bool: 'Schalter',
	int: 'Ganzzahl',
	double: 'Dezimalzahl',
	string: 'Text',
	enum: 'Auswahl',
	list: 'Liste'
};

/** Der Wert darf im Dashboard nicht geaendert werden. */
export const isReadOnly = (e: ConfigEntry) => e.locked;
/** Zuruecksetzen ist nur sinnvoll bei einem Dashboard-Wert. */
export const canReset = (e: ConfigEntry) => !e.locked && e.source === 'dashboard';

export const THRESHOLD_GROUP = 'Dashboard-Schwellen';

export interface Group {
	name: string;
	entries: ConfigEntry[];
}

/** Gruppen in Reihenfolge des ersten Auftretens; Suche ueber Schluessel und Beschreibung. */
export function groupEntries(
	entries: ConfigEntry[],
	opts: { query?: string; onlyChanged?: boolean } = {}
): Group[] {
	const q = (opts.query ?? '').trim().toLowerCase();
	const out: Group[] = [];
	for (const e of entries) {
		if (q && !`${e.key} ${e.description} ${e.group}`.toLowerCase().includes(q)) continue;
		if (opts.onlyChanged && e.source !== 'dashboard') continue;
		let g = out.find((x) => x.name === e.group);
		if (!g) out.push((g = { name: e.group, entries: [] }));
		g.entries.push(e);
	}
	return out;
}

/** Zusammenfassung "Alt -> Neu" fuer die Aenderungsbestaetigung. */
export function changeSummary(e: ConfigEntry, next: ConfigValue): { from: string; to: string } {
	return { from: formatValue(e), to: formatValue(e, next) };
}
