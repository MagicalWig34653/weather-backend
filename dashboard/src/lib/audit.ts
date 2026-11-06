/**
 * Darstellung und Filter des Protokolls (GET /config/audit). Der Server liefert Aktion, Schluessel,
 * Werte (Geheimnisse nie im Klartext), Geraetebezug (8 Hexzeichen) und Ergebnis; einen Akteur nennt der
 * Vertrag nicht: er wird aus der Aktion abgeleitet (nur der Notfall-Befehl laeuft ausserhalb des Dashboards).
 */
import { AUDIT_ACTIONS, type AuditEntry } from './api';

export const actionLabel: Record<string, string> = {
	set: 'Geändert',
	reset: 'Auf Standard',
	restart: 'Neustart',
	login: 'Anmeldung',
	setup: 'Einrichtung',
	reset_cli: 'Notfall-Reset',
	device_pair: 'Gerät gekoppelt',
	device_unpair: 'Kopplung widerrufen',
	device_action: 'Geräteaktion',
	push_pause: 'Push-Pause',
	cache_clear: 'Cache geleert'
};
export const labelOf = (action: string): string => actionLabel[action] ?? action;

/** Aktionen fuer den Filter, in fester Reihenfolge. */
export const actionOptions = AUDIT_ACTIONS.map((a) => ({ value: a, label: actionLabel[a] }));

export type Actor = 'operator' | 'cli';
export const actorLabel: Record<Actor, string> = {
	operator: 'Betreiber (Dashboard)',
	cli: 'Kommandozeile'
};
export const actorOf = (e: Pick<AuditEntry, 'action'>): Actor =>
	e.action === 'reset_cli' ? 'cli' : 'operator';

export type Period = 'all' | '24h' | '7d' | '30d';
export const periods: { value: Period; label: string; title: string; ms: number }[] = [
	{ value: 'all', label: 'Alle', title: 'Alle geladenen Einträge', ms: Infinity },
	{ value: '24h', label: '24 h', title: 'Letzte 24 Stunden', ms: 86_400_000 },
	{ value: '7d', label: '7 d', title: 'Letzte 7 Tage', ms: 7 * 86_400_000 },
	{ value: '30d', label: '30 d', title: 'Letzte 30 Tage', ms: 30 * 86_400_000 }
];

export interface Filter {
	period: Period;
	actor: Actor | 'all';
}

export function applyFilter(entries: AuditEntry[], f: Filter, now = Date.now()): AuditEntry[] {
	const span = periods.find((p) => p.value === f.period)?.ms ?? Infinity;
	return entries.filter(
		(e) =>
			(f.actor === 'all' || actorOf(e) === f.actor) &&
			(span === Infinity || now - new Date(e.at).getTime() <= span)
	);
}

export interface Page<T> {
	items: T[];
	page: number;
	pages: number;
	from: number;
	to: number;
	total: number;
}
/** Seite 1-basiert; ausserhalb des Bereichs wird begrenzt. */
export function paginate<T>(items: T[], page: number, size: number): Page<T> {
	const pages = Math.max(1, Math.ceil(items.length / size));
	const p = Math.min(Math.max(1, page), pages);
	const start = (p - 1) * size;
	const slice = items.slice(start, start + size);
	return {
		items: slice,
		page: p,
		pages,
		from: slice.length ? start + 1 : 0,
		to: start + slice.length,
		total: items.length
	};
}

const deviceKinds: Record<string, string> = {
	test: 'Testpush',
	la_probe: 'Live-Activity-Test',
	la_end: 'Live Activity beenden',
	reeval: 'Neuauswertung',
	reset_slot: 'Platz freigeben'
};
const outcomes: Record<string, string> = {
	delivered: 'zugestellt',
	rejected: 'abgelehnt',
	retry: 'wird wiederholt',
	dropped: 'verworfen',
	skipped: 'übersprungen'
};

/** "test:delivered" -> "Testpush: zugestellt"; unbekannte Formen unveraendert. */
export function outcomeText(outcome: string | null): string | null {
	if (!outcome) return null;
	const [kind, rest] = outcome.split(':', 2);
	if (rest === undefined) return outcome;
	return `${deviceKinds[kind] ?? kind}: ${outcomes[rest] ?? rest}`;
}

const MAX = 48;
/** Wert fuer Tabellenzellen: gekuerzt; der volle Wert steht in der Detailansicht. */
export function clip(v: string | null, max = MAX): string {
	if (v === null || v === '') return '–';
	return v.length > max ? `${v.slice(0, max - 1)}…` : v;
}

/** Kurzbeschreibung des Betreffs fuer die Tabelle. */
export function subject(e: AuditEntry): string {
	if (e.configKey) {
		if (e.action === 'set' || e.action === 'reset')
			return `${e.configKey}: ${clip(e.oldValue, 20)} → ${clip(e.newValue, 20)}`;
		return e.configKey;
	}
	if (e.action === 'restart' && e.newValue) return `Generation ${e.newValue}`;
	if (e.deviceRef) {
		const o = outcomeText(e.outcome);
		return o ? `Gerät ${e.deviceRef}, ${o}` : `Gerät ${e.deviceRef}`;
	}
	if (e.action === 'push_pause')
		return e.newValue === 'true'
			? 'Versand pausiert'
			: e.newValue === 'false'
				? 'Versand fortgesetzt'
				: '–';
	if (e.action === 'cache_clear') return e.outcome ? `Ebene ${e.outcome}` : '–';
	return '–';
}

/** Felder der Detailansicht; leere Felder entfallen. */
export function details(e: AuditEntry): { label: string; value: string; mono?: boolean }[] {
	const rows: { label: string; value: string; mono?: boolean }[] = [
		{ label: 'Nummer', value: String(e.id), mono: true },
		{ label: 'Zeitpunkt (UTC)', value: e.at, mono: true },
		{ label: 'Aktion', value: labelOf(e.action) },
		{ label: 'Akteur', value: actorLabel[actorOf(e)] }
	];
	const add = (label: string, v: string | null, mono = false) => {
		if (v !== null && v !== '') rows.push({ label, value: v, mono });
	};
	add('Schlüssel', e.configKey, true);
	add('Alter Wert', e.oldValue, true);
	add('Neuer Wert', e.newValue, true);
	add('Gerätebezug', e.deviceRef, true);
	add('Ergebnis', outcomeText(e.outcome));
	return rows;
}
