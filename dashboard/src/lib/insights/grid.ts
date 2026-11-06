/**
 * Radarraster des Servers (Rasterversion 1): Web-Mercator-Ausschnitt, 1024 x 1311 Zellen.
 * Nur Darstellung: der Server liefert Zellindizes und die gerundete Zellmitte, hier wird daraus das Gradnetz der Karte.
 */
export const GRID = {
	width: 1024,
	height: 1311,
	bbox: [612257.0, 5942074.0, 1736584.0, 7381298.0] as const,
	earthRadius: 6378137.0
};

/** Zellkoordinate (Bruchteile erlaubt) eines Punktes; ausserhalb des Rasters ebenfalls berechnet. */
export function cellOf(lat: number, lon: number, g = GRID): { x: number; y: number } {
	const X = (g.earthRadius * lon * Math.PI) / 180;
	const Y = g.earthRadius * Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360));
	return {
		x: ((X - g.bbox[0]) / (g.bbox[2] - g.bbox[0])) * g.width,
		y: ((g.bbox[3] - Y) / (g.bbox[3] - g.bbox[1])) * g.height
	};
}

/** Breite und Laenge der Mitte der Zelle (x, y). */
export function coordOf(x: number, y: number, g = GRID): { lat: number; lon: number } {
	const X = g.bbox[0] + ((x + 0.5) / g.width) * (g.bbox[2] - g.bbox[0]);
	const Y = g.bbox[3] - ((y + 0.5) / g.height) * (g.bbox[3] - g.bbox[1]);
	return {
		lon: ((X / g.earthRadius) * 180) / Math.PI,
		lat: (Math.atan(Math.sinh(Y / g.earthRadius)) * 180) / Math.PI
	};
}

export interface MapWindow {
	x0: number;
	y0: number;
	size: number;
}

/**
 * Quadratischer Ausschnitt (in Zellen) um alle Orte samt Umkreis. Mindestens `minSize` Zellen (etwa 100 km), hoechstens das Raster.
 */
export function mapWindow(
	places: { x: number; y: number; radius: number }[],
	g = GRID,
	minSize = 140
): MapWindow {
	if (places.length === 0) return { x0: 0, y0: 0, size: Math.min(g.width, g.height) };
	const pad = 12;
	const xs0 = Math.min(...places.map((p) => p.x - p.radius)) - pad;
	const xs1 = Math.max(...places.map((p) => p.x + p.radius + 1)) + pad;
	const ys0 = Math.min(...places.map((p) => p.y - p.radius)) - pad;
	const ys1 = Math.max(...places.map((p) => p.y + p.radius + 1)) + pad;
	const size = Math.min(
		Math.min(g.width, g.height),
		Math.max(minSize, Math.ceil(Math.max(xs1 - xs0, ys1 - ys0)))
	);
	const clamp = (v: number, max: number) => Math.max(0, Math.min(max - size, Math.round(v)));
	return {
		x0: clamp((xs0 + xs1) / 2 - size / 2, g.width),
		y0: clamp((ys0 + ys1) / 2 - size / 2, g.height),
		size
	};
}

export interface GraticuleLine {
	kind: 'lat' | 'lon';
	value: number;
	/** Zellkoordinate der Linie (y fuer Breitenkreise, x fuer Laengenkreise). */
	at: number;
}

/** Gradnetz im Ausschnitt; Schrittweite (Grad) so, dass hoechstens etwa 6 Linien je Richtung entstehen. */
export function graticule(win: MapWindow, g = GRID): { step: number; lines: GraticuleLine[] } {
	const nw = coordOf(win.x0, win.y0, g);
	const se = coordOf(win.x0 + win.size, win.y0 + win.size, g);
	const span = Math.max(nw.lat - se.lat, se.lon - nw.lon);
	const steps = [0.05, 0.1, 0.2, 0.25, 0.5, 1, 2];
	const step = steps.find((s) => span / s <= 6) ?? 2;
	const lines: GraticuleLine[] = [];
	for (let lat = Math.ceil(se.lat / step) * step; lat <= nw.lat; lat += step) {
		const v = Math.round(lat / step) * step;
		lines.push({ kind: 'lat', value: v, at: cellOf(v, nw.lon, g).y });
	}
	for (let lon = Math.ceil(nw.lon / step) * step; lon <= se.lon; lon += step) {
		const v = Math.round(lon / step) * step;
		lines.push({ kind: 'lon', value: v, at: cellOf(nw.lat, v, g).x });
	}
	return { step, lines };
}
