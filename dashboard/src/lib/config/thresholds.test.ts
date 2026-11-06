import { describe, expect, it } from 'vitest';
import type { ConfigEntry } from '../api';
import { RULES, checkPair, fromInput, thresholdRows, toInput } from './thresholds';

const entry = (key: string, value: number, group = 'Dashboard-Schwellen'): ConfigEntry => ({
	key,
	group,
	type: 'double',
	default: value,
	min: 0,
	max: 1,
	unit: null,
	description: '',
	apply: 'live',
	source: 'default',
	locked: false,
	value,
	restartPending: false
});

describe('thresholdRows', () => {
	it('paart gelb und rot je Regel und ordnet nach Regelliste', () => {
		const { rows, rest } = thresholdRows([
			entry('DASH_WARN_CACHE_HIT_RED', 0.5),
			entry('DASH_MIN_GROUP', 5),
			entry('DASH_WARN_ERROR_RATE_5XX_YELLOW', 0.005),
			entry('DASH_WARN_ERROR_RATE_5XX_RED', 0.02),
			entry('DASH_WARN_CACHE_HIT_YELLOW', 0.8),
			entry('CACHE_MAX_MB', 64, 'Cache')
		]);
		expect(rows.map((r) => r.def.rule)).toEqual(['ERROR_RATE_5XX', 'CACHE_HIT']);
		expect(rows[1].yellow?.value).toBe(0.8);
		expect(rest.map((x) => x.key)).toEqual(['DASH_MIN_GROUP']);
	});
	it('zeigt unbekannte Regeln des Servers an', () => {
		const { rows } = thresholdRows([
			entry('DASH_WARN_NEU_YELLOW', 1),
			entry('DASH_WARN_NEU_RED', 2)
		]);
		expect(rows).toHaveLength(1);
		expect(rows[0].def.label).toBe('NEU');
	});
	it('kennt alle Regeln des Vertrags', () => {
		expect(RULES.map((r) => r.rule).sort()).toEqual(
			[
				'LAYER_AGE_FACTOR',
				'ERROR_RATE_5XX',
				'OUTBOX_AGE_SECONDS',
				'APNS_REJECTION',
				'TOKEN_INVALIDATION',
				'CACHE_HIT',
				'CAP_FILL',
				'LA_START_RATIO'
			].sort()
		);
	});
});

describe('Prozent-Umrechnung', () => {
	it('zeigt Anteile in Prozent und liest sie zurueck', () => {
		expect(toInput('percent', 0.005)).toBe('0,5');
		expect(toInput('percent', 0.8)).toBe('80');
		expect(toInput('factor', 2)).toBe('2');
		expect(fromInput('percent', '0,5')).toBe(0.005);
		expect(fromInput('percent', ' 80 ')).toBe(0.8);
		expect(fromInput('percent', '33.3')).toBe(0.333);
		expect(fromInput('seconds', '120')).toBe(120);
	});
	it('rundet ohne Gleitkommarest', () => {
		expect(fromInput('percent', '7')).toBe(0.07);
		expect(fromInput('percent', '0,1')).toBe(0.001);
	});
	it('lehnt ungueltige Eingaben ab', () => {
		for (const t of ['', 'abc', '1,2,3', 'Infinity', '5%'])
			expect(fromInput('percent', t)).toBeNull();
		expect(toInput('percent', null)).toBe('');
	});
});

describe('checkPair', () => {
	const above = RULES.find((r) => r.rule === 'ERROR_RATE_5XX')!;
	const below = RULES.find((r) => r.rule === 'CACHE_HIT')!;
	it('verlangt gelb vor rot', () => {
		expect(checkPair(above, 0.005, 0.02)).toBeNull();
		expect(checkPair(above, 0.02, 0.005)).toMatch(/unter/);
		expect(checkPair(above, 0.02, 0.02)).not.toBeNull();
		expect(checkPair(below, 0.8, 0.5)).toBeNull();
		expect(checkPair(below, 0.5, 0.8)).toMatch(/über/);
	});
});
