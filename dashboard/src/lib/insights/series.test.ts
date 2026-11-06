import { describe, expect, it } from 'vitest';
import { bucketLabels, change, ratio, sum } from './series';

describe('series', () => {
	it('summiert und bildet Verhaeltnisse', () => {
		expect(sum([1, 2, 3])).toBe(6);
		expect(ratio(3, 1)).toBe(0.75);
		expect(ratio(0, 0)).toBeNull();
	});
	it('berechnet Aenderungen nur mit Vergleichswert', () => {
		expect(change(110, 100)).toBeCloseTo(0.1);
		expect(change(5, null)).toBeNull();
		expect(change(5, 0)).toBeNull();
	});
	it('beschriftet Zeitachsen je Bereich', () => {
		const t = ['2026-11-05T12:00:00Z'];
		expect(bucketLabels(t, '24h').categories).toHaveLength(1);
		expect(bucketLabels(t, '30d').ticks[0]).toMatch(/^\d{2}\.\d{2}\.$/);
	});
});
