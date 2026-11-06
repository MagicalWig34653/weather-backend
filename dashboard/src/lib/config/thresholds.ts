/**
 * Schwellen fuer Befunde (Gruppe "Dashboard-Schwellen", Schluessel DASH_WARN_<REGEL>_YELLOW/_RED).
 * Anteile liegen im Register als Bruchzahl 0..1, die Oberflaeche zeigt und erfasst Prozent.
 */
import type { ConfigEntry, ConfigValue } from '../api';
import { THRESHOLD_GROUP } from './form';

export type RuleUnit = 'percent' | 'factor' | 'seconds';

export interface RuleDef {
	rule: string;
	label: string;
	hint: string;
	/** above: Befund bei Werten oberhalb (gelb < rot); below: bei Werten unterhalb (gelb > rot). */
	direction: 'above' | 'below';
	unit: RuleUnit;
}

export const RULES: RuleDef[] = [
	{
		rule: 'LAYER_AGE_FACTOR',
		label: 'Ebene zu alt',
		hint: 'Alter des jüngsten Stands als Vielfaches des Takts.',
		direction: 'above',
		unit: 'factor'
	},
	{
		rule: 'ERROR_RATE_5XX',
		label: 'Fehlerquote (5xx)',
		hint: 'Anteil der Serverfehler in der letzten Stunde.',
		direction: 'above',
		unit: 'percent'
	},
	{
		rule: 'OUTBOX_AGE_SECONDS',
		label: 'Warteschlange staut sich',
		hint: 'Alter des ältesten wartenden Push-Eintrags.',
		direction: 'above',
		unit: 'seconds'
	},
	{
		rule: 'APNS_REJECTION',
		label: 'APNs-Ablehnungen',
		hint: 'Anteil abgelehnter Sendungen in der letzten Stunde.',
		direction: 'above',
		unit: 'percent'
	},
	{
		rule: 'TOKEN_INVALIDATION',
		label: 'Ungültige Token',
		hint: 'Anteil ungültig gewordener Token in 24 Stunden.',
		direction: 'above',
		unit: 'percent'
	},
	{
		rule: 'CACHE_HIT',
		label: 'Cache-Trefferquote',
		hint: 'Untere Grenze der Trefferquote in 24 Stunden.',
		direction: 'below',
		unit: 'percent'
	},
	{
		rule: 'CAP_FILL',
		label: 'Füllgrad der Obergrenzen',
		hint: 'Anteil der belegten Plätze (Installationen, Abos, Zellen).',
		direction: 'above',
		unit: 'percent'
	},
	{
		rule: 'LA_START_RATIO',
		label: 'Live-Activity-Startquote',
		hint: 'Untere Grenze: gestartete Live Activities je Auslöser (ab 10 Fällen).',
		direction: 'below',
		unit: 'percent'
	}
];

const KEY = /^DASH_WARN_(.+)_(YELLOW|RED)$/;

export interface ThresholdRow {
	def: RuleDef;
	yellow?: ConfigEntry;
	red?: ConfigEntry;
}

/** Schwellenzeilen in Reihenfolge der Regeln; unbekannte Regeln des Servers erscheinen mit dem Schluessel als Namen. */
export function thresholdRows(entries: ConfigEntry[]): {
	rows: ThresholdRow[];
	rest: ConfigEntry[];
} {
	const byRule = new Map<string, { yellow?: ConfigEntry; red?: ConfigEntry }>();
	const rest: ConfigEntry[] = [];
	for (const e of entries) {
		if (e.group !== THRESHOLD_GROUP) continue;
		const m = KEY.exec(e.key);
		if (!m) {
			rest.push(e);
			continue;
		}
		const slot = byRule.get(m[1]) ?? {};
		if (m[2] === 'YELLOW') slot.yellow = e;
		else slot.red = e;
		byRule.set(m[1], slot);
	}
	const rows: ThresholdRow[] = [];
	const known = new Set<string>();
	for (const def of RULES) {
		const s = byRule.get(def.rule);
		if (!s) continue;
		known.add(def.rule);
		rows.push({ def, ...s });
	}
	for (const [rule, s] of byRule) {
		if (known.has(rule)) continue;
		rows.push({
			def: { rule, label: rule, hint: '', direction: 'above', unit: 'factor' },
			...s
		});
	}
	return { rows, rest };
}

/** Faktor zwischen Registerwert und Eingabe (Prozent: 100). */
const scale = (u: RuleUnit) => (u === 'percent' ? 100 : 1);
const round = (n: number) => Number(n.toFixed(6));

export const toInput = (u: RuleUnit, v: ConfigValue): string =>
	typeof v === 'number'
		? new Intl.NumberFormat('de-DE', { maximumFractionDigits: 4, useGrouping: false }).format(
				round(v * scale(u))
			)
		: '';
/** Eingabe (Prozent bzw. Zahl, Komma erlaubt) -> Registerwert; null bei ungueltiger Eingabe. */
export function fromInput(u: RuleUnit, text: string): number | null {
	const t = text.trim().replace(',', '.');
	if (!/^[+-]?(\d+\.?\d*|\.\d+)$/.test(t)) return null;
	const n = Number(t);
	return Number.isFinite(n) ? round(n / scale(u)) : null;
}
export const unitSuffix = (u: RuleUnit): string =>
	u === 'percent' ? '%' : u === 'seconds' ? 's' : '× Takt';

/** Reihenfolge gelb/rot: Warnung muss vor "kritisch" greifen. Fehlertext oder null. */
export function checkPair(def: RuleDef, yellow: number, red: number): string | null {
	if (def.direction === 'above' && !(yellow < red))
		return 'Die Warnschwelle muss unter der kritischen Schwelle liegen.';
	if (def.direction === 'below' && !(yellow > red))
		return 'Die Warnschwelle muss über der kritischen Schwelle liegen.';
	return null;
}
