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
