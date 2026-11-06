import { describe, expect, it } from 'vitest';
import { activeItem, ALL_ITEMS } from './nav';

describe('nav', () => {
	it('findet Eintraege ohne Basispfad', () => {
		expect(activeItem('/')?.label).toBe('Übersicht');
		expect(activeItem('/betrieb/')?.label).toBe('Betrieb');
		expect(activeItem('/konfiguration')?.label).toBe('Konfiguration');
		expect(activeItem('/gibts-nicht')).toBeUndefined();
	});
	it('hat genau vier Tabs plus Mehr auf dem Telefon', () => {
		expect(ALL_ITEMS.filter((i) => i.tab)).toHaveLength(4);
	});
});
