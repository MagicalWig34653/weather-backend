import type {
	AssertionCredentialJSON,
	AttestationCredentialJSON,
	CreationOptionsJSON,
	RequestOptionsJSON
} from './api';

export type PasskeyErrorKind = 'unsupported' | 'cancelled' | 'timeout' | 'failed';

export class PasskeyError extends Error {
	constructor(
		readonly kind: PasskeyErrorKind,
		message: string
	) {
		super(message);
		this.name = 'PasskeyError';
	}
}

export function b64urlToBuffer(value: string): ArrayBuffer {
	const pad = '='.repeat((4 - (value.length % 4)) % 4);
	const bin = atob(value.replace(/-/g, '+').replace(/_/g, '/') + pad);
	const bytes = new Uint8Array(bin.length);
	for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	return bytes.buffer;
}

export function bufferToB64url(buffer: ArrayBuffer | ArrayBufferView): string {
	const bytes =
		buffer instanceof ArrayBuffer
			? new Uint8Array(buffer)
			: new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
	let bin = '';
	for (const b of bytes) bin += String.fromCharCode(b);
	return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function passkeysSupported(): boolean {
	return (
		typeof window !== 'undefined' &&
		window.isSecureContext === true &&
		typeof window.PublicKeyCredential !== 'undefined' &&
		!!navigator.credentials
	);
}

function mapError(error: unknown): PasskeyError {
	if (error instanceof PasskeyError) return error;
	const name = error instanceof DOMException ? error.name : '';
	if (name === 'NotAllowedError' || name === 'AbortError') {
		return new PasskeyError(
			'cancelled',
			'Der Vorgang wurde abgebrochen oder ist abgelaufen. Bitte erneut versuchen.'
		);
	}
	if (name === 'InvalidStateError') {
		return new PasskeyError('failed', 'Für dieses Gerät ist bereits ein Passkey vorhanden.');
	}
	if (name === 'SecurityError') {
		return new PasskeyError(
			'failed',
			'Die Adresse dieser Seite passt nicht zur Passkey-Konfiguration des Servers.'
		);
	}
	return new PasskeyError('failed', 'Der Passkey konnte nicht verarbeitet werden.');
}

function requireSupport(): void {
	if (!passkeysSupported()) {
		throw new PasskeyError(
			'unsupported',
			'Dieser Browser oder diese Verbindung unterstützt keine Passkeys (HTTPS erforderlich).'
		);
	}
}

export async function createPasskey(
	options: CreationOptionsJSON
): Promise<AttestationCredentialJSON> {
	requireSupport();
	try {
		const cred = (await navigator.credentials.create({
			publicKey: {
				...options,
				challenge: b64urlToBuffer(options.challenge),
				user: { ...options.user, id: b64urlToBuffer(options.user.id) }
			} as PublicKeyCredentialCreationOptions
		})) as PublicKeyCredential | null;
		if (!cred) throw new PasskeyError('cancelled', 'Es wurde kein Passkey erstellt.');
		const r = cred.response as AuthenticatorAttestationResponse;
		return {
			id: cred.id,
			rawId: bufferToB64url(cred.rawId),
			type: 'public-key',
			response: {
				clientDataJSON: bufferToB64url(r.clientDataJSON),
				attestationObject: bufferToB64url(r.attestationObject),
				transports: r.getTransports?.()
			}
		};
	} catch (e) {
		throw mapError(e);
	}
}

export async function getPasskey(options: RequestOptionsJSON): Promise<AssertionCredentialJSON> {
	requireSupport();
	try {
		const cred = (await navigator.credentials.get({
			publicKey: {
				...options,
				challenge: b64urlToBuffer(options.challenge),
				allowCredentials: options.allowCredentials?.map((c) => ({
					...c,
					id: b64urlToBuffer(c.id)
				})) as PublicKeyCredentialDescriptor[] | undefined
			} as PublicKeyCredentialRequestOptions
		})) as PublicKeyCredential | null;
		if (!cred) throw new PasskeyError('cancelled', 'Es wurde kein Passkey ausgewählt.');
		const r = cred.response as AuthenticatorAssertionResponse;
		return {
			id: cred.id,
			rawId: bufferToB64url(cred.rawId),
			type: 'public-key',
			response: {
				clientDataJSON: bufferToB64url(r.clientDataJSON),
				authenticatorData: bufferToB64url(r.authenticatorData),
				signature: bufferToB64url(r.signature),
				userHandle: r.userHandle ? bufferToB64url(r.userHandle) : null
			}
		};
	} catch (e) {
		throw mapError(e);
	}
}
