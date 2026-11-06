import { describe, expect, it } from 'vitest';
import { cellOf, coordOf, graticule, mapWindow } from './grid.js';

describe('Radarraster', () => {
	it('Zelle und Koordinate sind zueinander invers (erfundene Punkte)', () => {
		for (const [lat, lon] of [
			[53.0, 11.0],
			[50.0, 10.0],
			[47.5, 7.5],
			[51.5, 13.5]
		]) {
			const c = cellOf(lat, lon);
			const back = coordOf(Math.floor(c.x), Math.floor(c.y));
			expect(Math.abs(back.lat - lat)).toBeLessThan(0.011);
			expect(Math.abs(back.lon - lon)).toBeLessThan(0.011);
		}
	});
	it('Osten ist rechts (x waechst), Norden ist oben (y sinkt)', () => {
		expect(cellOf(50, 11).x).toBeGreaterThan(cellOf(50, 10).x);
		expect(cellOf(51, 10).y).toBeLessThan(cellOf(50, 10).y);
	});
	it('stimmt mit dem Server ueberein (Fixture: Zellmitte 50.00 / 10.00 ist Zelle 456/851)', () => {
		const c = coordOf(456, 851);
		expect(c.lat).toBeCloseTo(50.0, 1);
		expect(c.lon).toBeCloseTo(10.0, 1);
	});
	it('Ausschnitt: quadratisch, im Raster, enthaelt Orte samt Umkreis', () => {
		const w = mapWindow([
			{ x: 456, y: 851, radius: 0 },
			{ x: 466, y: 844, radius: 20 }
		]);
		expect(w.size).toBeGreaterThanOrEqual(140);
		for (const p of [
			{ x: 456, y: 851 },
			{ x: 446, y: 824 },
			{ x: 486, y: 864 }
		]) {
			expect(p.x).toBeGreaterThanOrEqual(w.x0);
			expect(p.x).toBeLessThan(w.x0 + w.size);
			expect(p.y).toBeGreaterThanOrEqual(w.y0);
			expect(p.y).toBeLessThan(w.y0 + w.size);
		}
		const edge = mapWindow([{ x: 2, y: 3, radius: 0 }]);
		expect(edge.x0).toBe(0);
		expect(edge.y0).toBe(0);
		const far = mapWindow([{ x: 1020, y: 1300, radius: 40 }]);
		expect(far.x0 + far.size).toBeLessThanOrEqual(1024);
		expect(far.y0 + far.size).toBeLessThanOrEqual(1311);
	});
	it('Gradnetz: wenige Linien, an der richtigen Stelle', () => {
		const w = mapWindow([{ x: 456, y: 851, radius: 0 }]);
		const g = graticule(w);
		expect(g.lines.length).toBeGreaterThan(0);
		expect(g.lines.length).toBeLessThanOrEqual(16);
		for (const l of g.lines) {
			const axis = l.kind === 'lat' ? w.y0 : w.x0;
			expect(l.at).toBeGreaterThanOrEqual(axis);
			expect(l.at).toBeLessThanOrEqual(axis + w.size);
		}
	});
});
