import type { PairingState } from './types';

/** Eingabepruefung der Geraetekopplung (Vertrag: POST devices/pair). */

const CROCKFORD = /^[0-9A-HJKMNP-TV-Z]{8}$/;

/** Normalisiert wie der Server: ohne Leerzeichen und Bindestrich, Grossbuchstaben, O->0, I und L->1. */
export function normalizeCode(input: string): string {
	return input.replace(/[\s-]/g, '').toUpperCase().replace(/O/g, '0').replace(/[IL]/g, '1');
}
export const isValidCode = (input: string): boolean => CROCKFORD.test(normalizeCode(input));
/** "7KQ2M9XD" -> "7KQ2-M9XD" (unvollstaendige Eingaben bleiben unveraendert). */
export const formatCode = (input: string): string => {
	const n = normalizeCode(input);
	return n.length === 8 ? `${n.slice(0, 4)}-${n.slice(4)}` : n;
};

export type LabelCheck = { ok: true; label: string } | { ok: false; error: string };
/** 1 bis 40 Zeichen nach dem Trimmen, keine Steuerzeichen. */
export function checkLabel(input: string): LabelCheck {
	const label = input.trim();
	if (label.length < 1) return { ok: false, error: 'Bitte eine Bezeichnung eingeben.' };
	if ([...label].length > 40) return { ok: false, error: 'Höchstens 40 Zeichen.' };
	if (/\p{Cc}/u.test(label)) return { ok: false, error: 'Steuerzeichen sind nicht erlaubt.' };
	return { ok: true, label };
}

// ------------------------------------------------------------ Kopplungsfenster

/** Waehlbare Dauern in Minuten (Vertrag: 1 bis `maxMinutes`, Standard `defaultMinutes`). */
export const PAIRING_MINUTES = [1, 5, 10, 15];
/** Abfrageabstand, solange das Fenster offen ist. */
export const PAIRING_POLL_MS = 10_000;
/** Ab so vielen Sekunden Restzeit gilt das Fenster als "laeuft ab". */
export const PAIRING_ENDING_SECONDS = 30;

export function pairingChoices(max: number): number[] {
	const list = PAIRING_MINUTES.filter((m) => m <= max);
	return list.length > 0 ? list : [1];
}
/** Vorauswahl: Serverstandard, sonst die naechste kleinere erlaubte Dauer. */
export function defaultChoice(def: number, max: number): number {
	const list = pairingChoices(max);
	return [...list].reverse().find((m) => m <= def) ?? list[0];
}

/** Restsekunden bis `endsAt` (aufgerundet, nie negativ; ungueltig = 0). */
export function remainingSeconds(endsAt: string | null, nowMs: number): number {
	if (!endsAt) return 0;
	const t = Date.parse(endsAt);
	return Number.isFinite(t) ? Math.max(0, Math.ceil((t - nowMs) / 1000)) : 0;
}
/** "04:07"; ab 100 Minuten wachsen die Minuten mit. */
export function formatCountdown(seconds: number): string {
	const s = Math.max(0, Math.floor(seconds));
	return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

export type PairingPhase = 'closed' | 'open' | 'ending' | 'expired';
/**
 * Anzeigezustand aus Serverzustand und Uhr. `expired`: der Server meldet noch offen, die Frist ist aber
 * schon verstrichen (Abfrage steht aus).
 */
export function pairingPhase(
	p: PairingState,
	nowMs: number
): { phase: PairingPhase; remaining: number } {
	if (!p.open) return { phase: 'closed', remaining: 0 };
	const remaining = remainingSeconds(p.endsAt, nowMs);
	if (remaining <= 0) return { phase: 'expired', remaining: 0 };
	return { phase: remaining <= PAIRING_ENDING_SECONDS ? 'ending' : 'open', remaining };
}
