import { describe, expect, it } from 'vitest';
import { isStale } from './states';

describe('isStale', () => {
	it('ist ohne Ladung nie veraltet', () => expect(isStale(null, 1e6, 6e4)).toBe(false));
	it('wird erst nach dem Doppelten des Intervalls veraltet', () => {
		expect(isStale(0, 119_999, 60_000)).toBe(false);
		expect(isStale(0, 120_001, 60_000)).toBe(true);
	});
});
