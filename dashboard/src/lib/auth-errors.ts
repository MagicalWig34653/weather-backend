import { ApiError } from './api';
import { PasskeyError } from './passkey';

/** "etwa 20 Sekunden" / "etwa 3 Minuten" aus Retry-After (Sekunden). */
export function waitText(seconds: number | null): string {
	if (seconds === null) return 'einen Moment';
	if (seconds < 90) return `etwa ${seconds} Sekunden`;
	return `etwa ${Math.ceil(seconds / 60)} Minuten`;
}

/** Text zu einem Fehler bei Einrichtung oder Anmeldung (Vertrag: Abschnitt Authentifizierung). */
export function authErrorText(e: unknown, setup: boolean): string {
	if (e instanceof PasskeyError) return e.message;
	if (!(e instanceof ApiError)) return 'Unbekannter Fehler.';
	if (e.serverCode === 'setup_closed')
		return 'Das Einrichtungsfenster ist abgelaufen. Das Dashboard muss neu gestartet werden.';
	switch (e.code) {
		case 'conflict':
			return setup
				? 'Es ist bereits ein Passkey eingerichtet. Seite neu laden und anmelden.'
				: 'Es ist noch kein Passkey eingerichtet. Seite neu laden.';
		case 'rate_limited':
			return `Zu viele Versuche. Bitte ${waitText(e.retryAfter)} warten.`;
		case 'unauthorized':
		case 'validation':
			return 'Anmeldung abgelehnt. Bitte erneut versuchen.';
		default:
			return e.message;
	}
}
