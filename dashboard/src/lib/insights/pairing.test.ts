import { describe, expect, it } from 'vitest';
import { checkLabel, formatCode, isValidCode, normalizeCode } from './pairing';

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
