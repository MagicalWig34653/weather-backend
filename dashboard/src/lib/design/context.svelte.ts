import { isStale } from './states';

export type Range = '24h' | '7d' | '30d';
export const RANGES: {
	value: Range;
	label: string;
	title: string;
	phrase: string;
	hours: number;
}[] = [
	{
		value: '24h',
		label: '24 h',
		title: 'Letzte 24 Stunden',
		phrase: 'in den letzten 24 Stunden',
		hours: 24
	},
	{
		value: '7d',
		label: '7 d',
		title: 'Letzte 7 Tage',
		phrase: 'in den letzten 7 Tagen',
		hours: 168
	},
	{
		value: '30d',
		label: '30 d',
		title: 'Letzte 30 Tage',
		phrase: 'in den letzten 30 Tagen',
		hours: 720
	}
];

export const REFRESH_MS = 30_000;
const EXPECTED_INTERVAL_MS = 60_000;

export function parseRange(v: string | null): Range {
	return v === '7d' || v === '30d' ? v : '24h';
}

/**
 * Gemeinsamer Anzeigezustand: Zeitbereich (in der URL gefuehrt, Shell uebernimmt ihn),
 * Aktualisieren-Zaehler und optionales Auto-Refresh (Polling, kein Stream).
 */
class DashContext {
	range = $state<Range>('24h');
	/** Seiten laden neu, sobald sich range oder tick aendern. */
	tick = $state(0);
	auto = $state(false);
	now = $state(Date.now());
	/** Zeitpunkt der letzten erfolgreichen Datenladung irgendeines Widgets. */
	updatedAt = $state<number | null>(null);

	refresh(): void {
		this.tick++;
	}
	stale(loadedAt: number | null): boolean {
		return isStale(loadedAt, this.now, EXPECTED_INTERVAL_MS);
	}
}

export const ctx = new DashContext();
