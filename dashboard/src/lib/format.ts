const nf = new Intl.NumberFormat('de-DE');
const pf = new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 });
const dtf = new Intl.DateTimeFormat('de-DE', { dateStyle: 'medium', timeStyle: 'short' });
const df = new Intl.DateTimeFormat('de-DE', { day: '2-digit', month: '2-digit', timeZone: 'UTC' });

export const formatNumber = (n: number): string => nf.format(n);
export const formatPercent = (ratio: number | null): string =>
	ratio === null ? '–' : pf.format(ratio);
export const formatDateTime = (iso: string | null): string =>
	iso ? dtf.format(new Date(iso)) : '–';
export const formatDay = (isoDate: string): string => df.format(new Date(isoDate + 'T00:00:00Z'));

export function formatBytes(n: number): string {
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	let v = n;
	let i = 0;
	while (v >= 1024 && i < units.length - 1) {
		v /= 1024;
		i++;
	}
	return `${new Intl.NumberFormat('de-DE', { maximumFractionDigits: i === 0 ? 0 : 1 }).format(v)} ${units[i]}`;
}

const tf = new Intl.DateTimeFormat('de-DE', {
	hour: '2-digit',
	minute: '2-digit',
	second: '2-digit'
});
const tfShort = new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit' });
const wdf = new Intl.DateTimeFormat('de-DE', {
	weekday: 'short',
	day: '2-digit',
	month: '2-digit'
});
const cf = new Intl.NumberFormat('de-DE', { notation: 'compact', maximumFractionDigits: 1 });

export const formatTime = (iso: string, seconds = true): string =>
	(seconds ? tf : tfShort).format(new Date(iso));
export const formatWeekday = (iso: string): string => wdf.format(new Date(iso));
/** Kompakte Zahl fuer Achsen: 12.345 -> "12.345", 1,2 Mio. */
export const formatCompact = (n: number): string =>
	Math.abs(n) < 10000 ? nf.format(n) : cf.format(n);

/** Dauer in Sekunden als "42 s", "5 min", "3,5 h", "2 d". */
export function formatDuration(seconds: number): string {
	const f = (v: number, u: string) =>
		`${new Intl.NumberFormat('de-DE', { maximumFractionDigits: v < 10 ? 1 : 0 }).format(v)} ${u}`;
	if (seconds < 90) return f(Math.round(seconds), 's');
	if (seconds < 5400) return f(seconds / 60, 'min');
	if (seconds < 129600) return f(seconds / 3600, 'h');
	return f(seconds / 86400, 'd');
}

export const formatMs = (ms: number): string => `${nf.format(Math.round(ms))} ms`;

/** Relative Aenderung als vorzeichenbehafteter Prozentwert ("+12,4 %"). */
export function formatDelta(ratio: number): string {
	const v = new Intl.NumberFormat('de-DE', {
		style: 'percent',
		maximumFractionDigits: 1,
		signDisplay: 'exceptZero'
	}).format(ratio);
	return v;
}

/** "vor 3 min" aus einem ISO-Zeitpunkt. */
export function formatAgo(iso: string | null, now = Date.now()): string {
	if (!iso) return '–';
	const s = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000));
	return `vor ${formatDuration(s)}`;
}
