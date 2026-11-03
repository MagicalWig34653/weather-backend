import { describe, expect, it } from 'vitest';
import { b64urlToBuffer, bufferToB64url, passkeysSupported } from './passkey';

describe('Base64URL', () => {
	it('wandelt hin und zurueck, auch bei Zeichen jenseits von ASCII', () => {
		const bytes = new Uint8Array([0, 1, 250, 251, 252, 253, 254, 255]);
		const text = bufferToB64url(bytes);
		expect(text).toBe('AAH6-_z9_v8');
		expect([...new Uint8Array(b64urlToBuffer(text))]).toEqual([...bytes]);
	});

	it('entfernt Padding und nutzt URL-sichere Zeichen', () => {
		const text = bufferToB64url(new Uint8Array([251, 255]));
		expect(text).not.toMatch(/[+/=]/);
	});

	it('akzeptiert Eingaben ohne Padding unterschiedlicher Laenge', () => {
		for (const n of [1, 2, 3, 4, 5]) {
			const bytes = Uint8Array.from({ length: n }, (_, i) => i * 51);
			expect([...new Uint8Array(b64urlToBuffer(bufferToB64url(bytes)))]).toEqual([...bytes]);
		}
	});

	it('meldet fehlende WebAuthn-Unterstuetzung', () => {
		expect(passkeysSupported()).toBe(false);
	});
});
