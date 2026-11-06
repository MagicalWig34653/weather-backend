import type { Bucket, Resolution, Series } from './types';

const hm = new Intl.DateTimeFormat('de-DE', {
	hour: '2-digit',
	minute: '2-digit',
	timeZone: 'UTC'
});
const wd = new Intl.DateTimeFormat('de-DE', { weekday: 'short', timeZone: 'UTC' });
const dm = new Intl.DateTimeFormat('de-DE', { day: '2-digit', month: '2-digit', timeZone: 'UTC' });

/** Zeitpunkte (UTC) und Werte einer Reihe; leer bei null. */
export function unpack(s: Series | null | undefined): { t: string[]; v: (number | null)[] } {
	return { t: (s?.points ?? []).map((p) => p.t), v: (s?.points ?? []).map((p) => p.v) };
}

/** Beschriftungen einer Zeitachse: lang (Tooltip, Tabelle) und kurz (Achse); Anzeige in UTC wie die Daten. */
export function bucketLabels(
	t: string[],
	resolution: Resolution
): { categories: string[]; ticks: string[] } {
	const d = t.map((x) => new Date(x));
	if (resolution === 'day') {
		return {
			categories: d.map((x) => `${wd.format(x)} ${dm.format(x)}`),
			ticks: d.map((x) => dm.format(x))
		};
	}
	const span = d.length > 1 ? d[d.length - 1].getTime() - d[0].getTime() : 0;
	if (span <= 30 * 3600_000) {
		return { categories: d.map((x) => hm.format(x)), ticks: d.map((x) => hm.format(x)) };
	}
	return {
		categories: d.map((x) => `${wd.format(x)} ${dm.format(x)}, ${hm.format(x)}`),
		ticks: d.map((x) => `${wd.format(x)} ${hm.format(x)}`)
	};
}

export const sum = (a: (number | null)[]): number => a.reduce<number>((s, v) => s + (v ?? 0), 0);

/** Summe der gezaehlten, nicht unterdrueckten Eintraege. */
export const bucketSum = (b: Bucket[]): number => b.reduce((s, x) => s + (x.count ?? 0), 0);

/** Verhaeltnis a/(a+b); null ohne Nenner. */
export function ratio(a: number, b: number): number | null {
	return a + b > 0 ? a / (a + b) : null;
}

/** Wandelt deltaPct (Prozent) in einen Anteil (0,064). */
export const deltaRatio = (pct: number | null): number | null => (pct === null ? null : pct / 100);

/** Letzte n Werte, null-Luecken als 0 fuer Sparklines (nur Zierde). */
export const sparkValues = (s: Series | null): number[] => unpack(s).v.map((v) => v ?? 0);
