import { describe, expect, it } from 'vitest';
import { ApiError } from '#lib/api.js';
import { failureReason, isRetryable, retryDelayMs } from './refresh';

const err = (status: number, code: ApiError['code'], retryAfter: number | null = null) =>
	new ApiError(status, code, 'x', retryAfter);

describe('Wiederholung', () => {
	it('wiederholt nicht bei 401/403/404/400', () => {
		for (const c of ['unauthorized', 'forbidden', 'not_found', 'validation'] as const)
			expect(isRetryable(err(400, c))).toBe(false);
		expect(isRetryable(err(0, 'timeout'))).toBe(true);
		expect(isRetryable(err(503, 'unavailable'))).toBe(true);
		expect(isRetryable(err(503, 'unavailable', 60))).toBe(false);
	});
	it('wartet bei 429 auf Retry-After (gedeckelt), sonst Backoff', () => {
		expect(retryDelayMs(err(429, 'rate_limited', 7), 1)).toBe(7000);
		expect(retryDelayMs(err(429, 'rate_limited', 600), 1)).toBe(30_000);
		expect(retryDelayMs(err(503, 'unavailable', 5), 1)).toBe(5000);
		expect(retryDelayMs(err(0, 'network'), 1, () => 0.5)).toBe(1500);
		expect(retryDelayMs(err(0, 'network'), 2, () => 0.5)).toBe(4000);
	});
	it('nennt den konkreten Grund', () => {
		expect(failureReason(err(0, 'timeout'))).toMatch(/Zeitüberschreitung/);
		expect(failureReason(err(0, 'network'))).toMatch(/Netzwerk/);
		expect(failureReason(err(429, 'rate_limited', 5))).toMatch(/429.*5 s/);
		expect(failureReason(err(401, 'unauthorized'))).toMatch(/401/);
	});
});
