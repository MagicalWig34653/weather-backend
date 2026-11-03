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
