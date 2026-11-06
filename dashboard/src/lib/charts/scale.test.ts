import { describe, expect, it } from 'vitest';
import { areaPath, linear, linePath, nearestIndex, niceTicks, tickIndices } from './scale';

describe('niceTicks', () => {
	it('liefert schoene Schritte', () => {
		const t = niceTicks(0, 9300, 4);
		expect(t.ticks).toEqual([0, 2500, 5000, 7500, 10000]);
		expect(t.max).toBe(10000);
	});
	it('behandelt flache Reihen', () => {
		const t = niceTicks(0, 0);
		expect(t.max).toBeGreaterThan(t.min);
	});
	it('behandelt Bruchwerte ohne Gleitkommarauschen', () => {
		expect(niceTicks(0, 1, 5).ticks).toEqual([0, 0.2, 0.4, 0.6, 0.8, 1]);
	});
});

describe('linear', () => {
	it('bildet Bereiche ab und kehrt um', () => {
		const y = linear(0, 100, 200, 0);
		expect(y(0)).toBe(200);
		expect(y(100)).toBe(0);
		expect(y(50)).toBe(100);
	});
});

describe('linePath', () => {
	it('unterbricht bei null', () => {
		expect(linePath([0, 1, 2, 3], [1, 2, null, 4])).toBe('M0,1L1,2M3,4');
	});
});

describe('areaPath', () => {
	it('schliesst zur Grundlinie', () => {
		expect(areaPath([0, 10], [5, 3], 20)).toBe('M0,5L10,3L10,20L0,20Z');
	});
});

describe('nearestIndex / tickIndices', () => {
	it('klemmt in den Wertebereich', () => {
		expect(nearestIndex(-50, 0, 100, 5)).toBe(0);
		expect(nearestIndex(500, 0, 100, 5)).toBe(4);
		expect(nearestIndex(50, 0, 100, 5)).toBe(2);
	});
	it('begrenzt Beschriftungen', () => {
		const idx = tickIndices(168, 6);
		expect(idx.length).toBeLessThanOrEqual(7);
		expect(idx[0]).toBe(0);
		expect(tickIndices(3, 6)).toEqual([0, 1, 2]);
	});
});

import { bandPath } from './scale';
describe('bandPath', () => {
	it('geht oben vorwaerts und unten rueckwaerts', () => {
		expect(bandPath([0, 10], [2, 3], [8, 8])).toBe('M0,2L10,3L10,8L0,8Z');
	});
});

import { bytesUnit } from './scale';
describe('bytesUnit', () => {
	it('waehlt die passende Einheit', () => {
		expect(bytesUnit(900)).toBe(1);
		expect(bytesUnit(5 * 1024 * 1024)).toBe(1024 * 1024);
		expect(bytesUnit(3 * 1024 ** 3)).toBe(1024 ** 3);
	});
});
