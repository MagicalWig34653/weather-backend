import { describe, expect, it } from 'vitest';
import { ApiError, codeFor, messageFor } from './api';
import { authErrorText, waitText } from './auth-errors';
import { PasskeyError } from './passkey';

const err = (status: number, serverCode: string | null, retry: number | null = null) =>
	new ApiError(status, codeFor(status), messageFor(status, serverCode), retry, serverCode);

describe('authErrorText', () => {
	it('unterscheidet Einrichtung und Anmeldung bei 409', () => {
		expect(authErrorText(err(409, 'conflict'), true)).toMatch(/bereits ein Passkey/);
		expect(authErrorText(err(409, 'conflict'), false)).toMatch(/noch kein Passkey/);
	});
	it('erkennt das geschlossene Einrichtungsfenster', () => {
		expect(authErrorText(err(403, 'setup_closed'), true)).toMatch(/neu gestartet/);
	});
	it('nennt die Wartezeit bei 429', () => {
		expect(authErrorText(err(429, 'rate_limited', 20), false)).toMatch(/etwa 20 Sekunden/);
		expect(authErrorText(err(429, 'rate_limited', 300), false)).toMatch(/etwa 5 Minuten/);
		expect(authErrorText(err(429, 'rate_limited'), false)).toMatch(/einen Moment/);
	});
	it('meldet abgelehnte Anmeldung ohne Details', () => {
		expect(authErrorText(err(401, 'unauthorized'), false)).toBe(
			'Anmeldung abgelehnt. Bitte erneut versuchen.'
		);
		expect(authErrorText(err(400, 'validation'), true)).toMatch(/abgelehnt/);
	});
	it('reicht Passkey- und unbekannte Fehler durch', () => {
		expect(authErrorText(new PasskeyError('cancelled', 'Abgebrochen.'), false)).toBe(
			'Abgebrochen.'
		);
		expect(authErrorText(new Error('x'), false)).toBe('Unbekannter Fehler.');
		expect(authErrorText(err(0, null), false)).not.toBe('');
		expect(waitText(89)).toBe('etwa 89 Sekunden');
	});
});
