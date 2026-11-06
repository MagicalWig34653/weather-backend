/** Reine Hilfsfunktionen fuer die SVG-Diagramme (testbar ohne DOM). */

export interface Ticks {
	ticks: number[];
	min: number;
	max: number;
}

/** "Schoene" Achsenwerte (1, 2, 2,5, 5 x 10^n) fuer den Bereich min..max. */
export function niceTicks(min: number, max: number, count = 4): Ticks {
	if (!Number.isFinite(min) || !Number.isFinite(max)) return { ticks: [0, 1], min: 0, max: 1 };
	if (max === min) max = min + (min === 0 ? 1 : Math.abs(min) * 0.1);
	const rough = (max - min) / Math.max(1, count);
	const pow = Math.pow(10, Math.floor(Math.log10(rough)));
	const frac = rough / pow;
	const step = (frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 2.5 ? 2.5 : frac <= 5 ? 5 : 10) * pow;
	const lo = Math.floor(min / step) * step;
	const hi = Math.ceil(max / step) * step;
	const ticks: number[] = [];
	for (let v = lo; v <= hi + step / 2; v += step) ticks.push(Number(v.toPrecision(12)));
	return { ticks, min: lo, max: hi };
}

export type Scale = (v: number) => number;

export function linear(d0: number, d1: number, r0: number, r1: number): Scale {
	const span = d1 - d0 || 1;
	return (v) => r0 + ((v - d0) / span) * (r1 - r0);
}

/** Pfad einer Linie; null-Werte unterbrechen sie (Luecke statt Interpolation). */
export function linePath(xs: number[], ys: (number | null)[]): string {
	let d = '';
	let open = false;
	ys.forEach((y, i) => {
		if (y === null || Number.isNaN(y)) {
			open = false;
			return;
		}
		d += `${open ? 'L' : 'M'}${round(xs[i])},${round(y)}`;
		open = true;
	});
	return d;
}

/** Flaechenpfad zwischen Linie und Grundlinie (nur fuer lueckenlose Reihen). */
export function areaPath(xs: number[], ys: number[], base: number): string {
	if (ys.length === 0) return '';
	const top = ys.map((y, i) => `${i === 0 ? 'M' : 'L'}${round(xs[i])},${round(y)}`).join('');
	return `${top}L${round(xs[xs.length - 1])},${round(base)}L${round(xs[0])},${round(base)}Z`;
}

export function round(n: number): number {
	return Math.round(n * 100) / 100;
}

/** Index des naechsten Punkts zu einer x-Position bei gleichmaessiger Verteilung. */
export function nearestIndex(x: number, left: number, right: number, n: number): number {
	if (n <= 1) return 0;
	const t = (x - left) / (right - left || 1);
	return Math.min(n - 1, Math.max(0, Math.round(t * (n - 1))));
}

/** Indizes fuer x-Achsenbeschriftungen: hoechstens `max`, gleichmaessig, erster und letzter inklusive. */
export function tickIndices(n: number, max: number): number[] {
	if (n <= 0) return [];
	if (n <= max) return Array.from({ length: n }, (_, i) => i);
	const step = Math.ceil((n - 1) / (max - 1));
	const out: number[] = [];
	for (let i = 0; i < n; i += step) out.push(i);
	return out;
}

export type SeriesColor = 1 | 2 | 3 | 4 | 5 | 'ok' | 'warn' | 'err';

/** Klassen je Farbe (vollstaendig ausgeschrieben, damit Tailwind sie findet). */
export const colorClass: Record<
	string,
	{ stroke: string; fill: string; bg: string; text: string }
> = {
	1: { stroke: 'stroke-chart-1', fill: 'fill-chart-1', bg: 'bg-chart-1', text: 'text-chart-1' },
	2: { stroke: 'stroke-chart-2', fill: 'fill-chart-2', bg: 'bg-chart-2', text: 'text-chart-2' },
	3: { stroke: 'stroke-chart-3', fill: 'fill-chart-3', bg: 'bg-chart-3', text: 'text-chart-3' },
	4: { stroke: 'stroke-chart-4', fill: 'fill-chart-4', bg: 'bg-chart-4', text: 'text-chart-4' },
	5: { stroke: 'stroke-chart-5', fill: 'fill-chart-5', bg: 'bg-chart-5', text: 'text-chart-5' },
	ok: { stroke: 'stroke-ok-fill', fill: 'fill-ok-fill', bg: 'bg-ok-fill', text: 'text-ok-fill' },
	warn: {
		stroke: 'stroke-warn-fill',
		fill: 'fill-warn-fill',
		bg: 'bg-warn-fill',
		text: 'text-warn-fill'
	},
	err: {
		stroke: 'stroke-err-fill',
		fill: 'fill-err-fill',
		bg: 'bg-err-fill',
		text: 'text-err-fill'
	}
};

/** Band zwischen Oberkante und Unterkante (gestapelte Flaechen). */
export function bandPath(xs: number[], top: number[], bottom: number[]): string {
	if (top.length === 0) return '';
	const fwd = top.map((y, i) => `${i === 0 ? 'M' : 'L'}${round(xs[i])},${round(y)}`).join('');
	const back = bottom
		.map((y, i) => `L${round(xs[i])},${round(y)}`)
		.reverse()
		.join('');
	return `${fwd}${back}Z`;
}

/** Teiler fuer Byte-Achsen: 1024^n passend zur Groesse, damit Ticks auf runden MB/GB liegen. */
export function bytesUnit(max: number): number {
	let u = 1;
	while (max / u >= 1024 && u < 1024 ** 4) u *= 1024;
	return u;
}
