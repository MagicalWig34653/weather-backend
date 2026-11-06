import { ApiError } from '#lib/api.js';
import { errorText } from '#lib/errors.js';

/** Fehler, bei denen ein erneuter Versuch sinnlos ist (Sitzung, Berechtigung, Eingabe, Pfad). */
export function isRetryable(e: unknown): boolean {
	if (!(e instanceof ApiError)) return true;
	// Vertrag 6.11.2026: 503/429 mit Retry-After groesser 30 s nicht still wiederholen.
	if (e.retryAfter !== null && e.retryAfter > 30) return false;
	return !['unauthorized', 'forbidden', 'not_found', 'validation'].includes(e.code);
}

/** Maximale Wartezeit auf Retry-After, damit ein Retry nicht minutenlang haengt. */
const MAX_RETRY_AFTER_MS = 30_000;

/**
 * Wartezeit vor dem n-ten stillen Wiederholungsversuch (attempt ab 1): 1,5 s, 4 s, ...
 * mit Streuung; bei 429 gilt Retry-After (hoechstens 30 s).
 */
export function retryDelayMs(
	e: unknown,
	attempt: number,
	random: () => number = Math.random
): number {
	if (e instanceof ApiError && e.retryAfter) {
		return Math.min(e.retryAfter * 1000, MAX_RETRY_AFTER_MS);
	}
	const base = attempt <= 1 ? 1500 : 4000;
	return Math.round(base * (0.8 + random() * 0.4));
}

/** Konkreter Grund fuer den Hinweis "Aktualisierung fehlgeschlagen". */
export function failureReason(e: unknown): string {
	if (e instanceof ApiError) {
		switch (e.code) {
			case 'timeout':
				return 'Zeitüberschreitung: der Server hat nicht rechtzeitig geantwortet.';
			case 'network':
				return 'Netzwerkfehler: der Server ist nicht erreichbar.';
			case 'rate_limited':
				return e.retryAfter
					? `Zu viele Anfragen (429), erneut möglich in ${e.retryAfter} s.`
					: 'Zu viele Anfragen (429).';
			case 'unauthorized':
				return 'Sitzung abgelaufen (401).';
			case 'unavailable':
				return `Dienst vorübergehend nicht verfügbar (${e.status}).`;
			default:
				return e.status > 0 ? `${e.message} (${e.status})` : e.message;
		}
	}
	return errorText.unknown;
}

/** Ab so vielen aufeinanderfolgenden fehlgeschlagenen Ladevorgaengen (je mit stillen Wiederholungen) erscheint der Hinweis. */
export const FAILURES_BEFORE_NOTICE = 2;
