import { describe, expect, it } from 'vitest';
import { bucketLabels, bucketSum, deltaRatio, ratio, sum, unpack } from './series';

describe('series', () => {
	it('summiert und bildet Verhaeltnisse', () => {
		expect(sum([1, null, 3])).toBe(4);
		expect(ratio(3, 1)).toBe(0.75);
		expect(ratio(0, 0)).toBeNull();
		expect(deltaRatio(6.4)).toBeCloseTo(0.064);
		expect(deltaRatio(null)).toBeNull();
	});
	it('entpackt fehlende und leere Reihen', () => {
		expect(unpack(null)).toEqual({ t: [], v: [] });
		expect(unpack({ resolution: 'hour', points: [{ t: 'x', v: null }] }).v).toEqual([null]);
	});
	it('zaehlt unterdrueckte Buckets nicht', () => {
		expect(
			bucketSum([
				{ key: 'a', count: 5, suppressed: false },
				{ key: 'b', count: null, suppressed: true }
			])
		).toBe(5);
	});
	it('beschriftet Zeitachsen je Aufloesung (UTC)', () => {
		const h = ['2026-11-05T12:00:00Z', '2026-11-05T13:00:00Z'];
		expect(bucketLabels(h, 'hour').ticks[0]).toBe('12:00');
		const long = ['2026-11-03T12:00:00Z', '2026-11-06T12:00:00Z'];
		expect(bucketLabels(long, 'hour').categories[0]).toContain('03.11.');
		expect(bucketLabels(['2026-11-05T00:00:00Z'], 'day').ticks[0]).toBe('05.11.');
	});
});
