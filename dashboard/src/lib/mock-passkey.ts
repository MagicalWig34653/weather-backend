/** Platzhalter-Credential fuer den Mock-Modus (ohne Authenticator). Nur von auth-panel im Mock-Build geladen. */
export function mockCredential() {
	return {
		id: 'mock',
		rawId: 'mock',
		type: 'public-key' as const,
		response: { clientDataJSON: '', attestationObject: '' }
	};
}
