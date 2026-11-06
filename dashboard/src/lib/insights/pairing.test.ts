import { describe, expect, it } from 'vitest';
import {
	checkLabel,
	defaultChoice,
	formatCode,
	formatCountdown,
	isValidCode,
	normalizeCode,
	pairingChoices,
	pairingPhase,
	remainingSeconds
} from './pairing';

describe('Koppelcode', () => {
	it('normalisiert wie der Server', () => {
		expect(normalizeCode(' 7kq2 - m9xd ')).toBe('7KQ2M9XD');
		expect(normalizeCode('oOiIlL')).toBe('001111');
	});
	it('prueft Alphabet (Crockford ohne I L O U) und Laenge', () => {
		expect(isValidCode('7KQ2-M9XD')).toBe(true);
		expect(isValidCode('7kq2m9xd')).toBe(true);
		expect(isValidCode('O0I1L1AB')).toBe(true); // wird zu 00111 1AB normalisiert
		expect(isValidCode('7KQ2-M9XU')).toBe(false); // U gibt es nicht
		expect(isValidCode('7KQ2-M9X')).toBe(false);
		expect(isValidCode('7KQ2-M9XDD')).toBe(false);
		expect(isValidCode('')).toBe(false);
		expect(isValidCode('7KQ2-M9X!')).toBe(false);
	});
	it('formatiert mit Bindestrich', () => {
		expect(formatCode('7kq2m9xd')).toBe('7KQ2-M9XD');
		expect(formatCode('7kq2')).toBe('7KQ2');
	});
});

describe('Bezeichnung', () => {
	it('trimmt und begrenzt auf 40 Zeichen', () => {
		expect(checkLabel('  Mein iPhone ')).toEqual({ ok: true, label: 'Mein iPhone' });
		expect(checkLabel('x'.repeat(40)).ok).toBe(true);
		expect(checkLabel('x'.repeat(41)).ok).toBe(false);
		expect(checkLabel('   ').ok).toBe(false);
		expect(checkLabel('a\nb').ok).toBe(false);
	});
	it('zaehlt Zeichen, nicht UTF-16-Einheiten', () => {
		expect(checkLabel('📱'.repeat(40)).ok).toBe(true);
	});
});

describe('Kopplungsfenster', () => {
	const now = Date.parse('2026-11-06T14:00:00Z');
	const win = (s: number) => new Date(now + s * 1000).toISOString();

	it('Dauerwahl: 1/5/10/15 begrenzt durch das Maximum, Standard 5', () => {
		expect(pairingChoices(15)).toEqual([1, 5, 10, 15]);
		expect(pairingChoices(10)).toEqual([1, 5, 10]);
		expect(pairingChoices(0)).toEqual([1]);
		expect(defaultChoice(5, 15)).toBe(5);
		expect(defaultChoice(7, 15)).toBe(5);
		expect(defaultChoice(20, 10)).toBe(10);
		expect(defaultChoice(0, 15)).toBe(1);
	});
	it('Restzeit mit fester Uhr', () => {
		expect(remainingSeconds(win(300), now)).toBe(300);
		expect(remainingSeconds(win(0.2), now)).toBe(1);
		expect(remainingSeconds(win(-5), now)).toBe(0);
		expect(remainingSeconds(null, now)).toBe(0);
		expect(remainingSeconds('kaputt', now)).toBe(0);
	});
	it('formatiert mm:ss', () => {
		expect(formatCountdown(300)).toBe('05:00');
		expect(formatCountdown(65)).toBe('01:05');
		expect(formatCountdown(0)).toBe('00:00');
		expect(formatCountdown(-3)).toBe('00:00');
		expect(formatCountdown(900)).toBe('15:00');
	});
	it('Phasen: geschlossen, offen, laeuft ab, abgelaufen', () => {
		expect(pairingPhase({ open: false, endsAt: null }, now)).toEqual({
			phase: 'closed',
			remaining: 0
		});
		expect(pairingPhase({ open: true, endsAt: win(240) }, now).phase).toBe('open');
		expect(pairingPhase({ open: true, endsAt: win(31) }, now).phase).toBe('open');
		expect(pairingPhase({ open: true, endsAt: win(30) }, now)).toEqual({
			phase: 'ending',
			remaining: 30
		});
		expect(pairingPhase({ open: true, endsAt: win(0) }, now).phase).toBe('expired');
		expect(pairingPhase({ open: true, endsAt: win(-10) }, now).phase).toBe('expired');
		// Server sagt geschlossen, auch wenn noch eine Frist drinsteht
		expect(pairingPhase({ open: false, endsAt: win(100) }, now).phase).toBe('closed');
	});
});
