import type { Range } from './types';

const hm = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit' });
const wd = new Intl.DateTimeFormat('de-DE', { weekday: 'short' });
const dm = new Intl.DateTimeFormat('de-DE', { day: '2-digit', month: '2-digit' });

/** Beschriftungen fuer eine Zeitachse: lang (Tooltip, Tabelle) und kurz (Achse). */
export function bucketLabels(t: string[], range: Range): { categories: string[]; ticks: string[] } {
	const d = t.map((x) => new Date(x));
	if (range === '24h')
		return { categories: d.map((x) => hm.format(x)), ticks: d.map((x) => hm.format(x)) };
	if (range === '7d')
		return {
			categories: d.map((x) => `${wd.format(x)} ${dm.format(x)}, ${hm.format(x)}`),
			ticks: d.map((x) => `${wd.format(x)} ${dm.format(x)}`)
		};
	return {
		categories: d.map((x) => `${wd.format(x)} ${dm.format(x)}`),
		ticks: d.map((x) => `${dm.format(x)}`)
	};
}

export const sum = (a: number[]): number => a.reduce((s, v) => s + v, 0);

/** Verhaeltnis a/(a+b); null ohne Nenner. */
export function ratio(a: number, b: number): number | null {
	return a + b > 0 ? a / (a + b) : null;
}

/** Relative Aenderung gegenueber dem Vorzeitraum; null ohne Vergleich. */
export function change(value: number, previous: number | null): number | null {
	return previous === null || previous === 0 ? null : value / previous - 1;
}
