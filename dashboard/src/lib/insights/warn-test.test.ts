import { afterEach, describe, expect, it, vi } from 'vitest';
import { api } from '#lib/client.js';
import { errorText } from '#lib/errors.js';
import { insights } from './api';
import { commandErrorName, commandKindName, commandResultText, eventKindName } from './text';

describe('Testwarnung', () => {
	afterEach(() => vi.restoreAllMocks());

	it('sendet Typ und Stufe, Standard Frost Stufe 1', async () => {
		const post = vi.spyOn(api, 'post').mockResolvedValue({});
		await insights.runAction('d1', 'warn-test');
		await insights.runAction('d1', 'warn-test', undefined, { type: 'ice', level: 4 });
		expect(post).toHaveBeenNthCalledWith(1, '/devices/d1/actions/warn-test', {
			type: 'frost',
			level: 1
		});
		expect(post).toHaveBeenNthCalledWith(2, '/devices/d1/actions/warn-test', {
			type: 'ice',
			level: 4
		});
	});

	it('hat deutsche Texte fuer Auftrag, Ergebnis, Fehler und Hinweis', () => {
		expect(commandKindName.warn_test).toBe('Testwarnung');
		expect(eventKindName.warn_test).toBe('Testwarnung');
		expect(commandErrorName.warn_push_disabled).toContain('WARN_PUSH_ENABLED');
		expect(errorText.no_warn_subscription).toContain('Warn-Abo');
		expect(
			commandResultText('warn_test', { outcome: 'delivered', apnsStatus: 200, reason: null })
		).toBe('Testwarnung von APNs angenommen (HTTP 200).');
		expect(
			commandResultText('warn_test', {
				outcome: 'dropped',
				apnsStatus: null,
				reason: null,
				skipped: 'no_warn_subscription'
			})
		).toBe('Nicht gesendet: Kein aktives Warn-Abo auf dem Gerät.');
		expect(
			commandResultText('warn_test', {
				outcome: 'rejected',
				apnsStatus: 400,
				reason: 'BadDeviceToken'
			})
		).toBe('Testwarnung abgelehnt: BadDeviceToken.');
	});
});
