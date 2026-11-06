/**
 * API-Vertrag des Dashboards: docs-site/content/dashboard-api.md (eingefroren, Feldnamen camelCase).
 * Alle Routen liegen unter /dash/api, sind JSON-only und liefern Cache-Control: no-store.
 * Fehlerantworten tragen nur {"error":"<code>"}; der Text wird hier nach Code und Status gewaehlt.
 */
import { errorText } from './errors';

// ---------------------------------------------------------------- Sitzung

export interface CredentialInfo {
	/** Anzeigename des Passkeys (kein Personenbezug). */
	name: string;
	/** ISO-8601-Zeitpunkt der Registrierung; so faellt eine Fremdregistrierung auf. */
	createdAt: string;
}

export type SessionState =
	| { state: 'setupOpen'; minutesLeft: number }
	| { state: 'setupClosed' }
	| { state: 'login' }
	| { state: 'authenticated'; csrfToken: string; credential: CredentialInfo };

// ---------------------------------------------------------------- Passkey (WebAuthn, Base64URL)

export interface CredentialDescriptorJSON {
	type: 'public-key';
	id: string;
	transports?: string[];
}

export interface CreationOptionsJSON {
	rp: { id: string; name: string };
	user: { id: string; name: string; displayName: string };
	challenge: string;
	pubKeyCredParams: { type: 'public-key'; alg: number }[];
	timeout?: number;
	attestation?: 'none';
	authenticatorSelection?: {
		residentKey?: 'required' | 'preferred' | 'discouraged';
		userVerification?: 'required' | 'preferred' | 'discouraged';
	};
}

export interface RequestOptionsJSON {
	challenge: string;
	rpId: string;
	timeout?: number;
	userVerification?: 'required' | 'preferred' | 'discouraged';
	allowCredentials?: CredentialDescriptorJSON[];
}

export interface BeginResponse<T> {
	/** Verweist auf die einmalig nutzbare Challenge in der Datenbank (5 Minuten gueltig). */
	challengeId: string;
	options: T;
}

export interface AttestationCredentialJSON {
	id: string;
	rawId: string;
	type: 'public-key';
	response: { clientDataJSON: string; attestationObject: string; transports?: string[] };
}

export interface AssertionCredentialJSON {
	id: string;
	rawId: string;
	type: 'public-key';
	response: {
		clientDataJSON: string;
		authenticatorData: string;
		signature: string;
		userHandle: string | null;
	};
}

// ---------------------------------------------------------------- Konfiguration

/** Typ im Register; unbekannte Werte werden wie `string` behandelt (offene Aufzaehlung). */
export type ConfigType = 'bool' | 'int' | 'double' | 'string' | 'enum' | 'list' | (string & {});
export type ConfigSource = 'env' | 'dashboard' | 'default';
/** live: wirkt nach hoechstens 30 s; restart: erst nach Neustart. */
export type ConfigApply = 'live' | 'restart';
/** Typisierter Wert: Zahl, Wahrheitswert, Text oder Liste; null bei Geheimnissen und ENV-only-Schluesseln. */
export type ConfigValue = string | number | boolean | string[] | null;

export interface ConfigEntry {
	key: string;
	group: string;
	type: ConfigType;
	default: ConfigValue;
	min: number | null;
	max: number | null;
	unit: string | null;
	description: string;
	apply: ConfigApply;
	source: ConfigSource;
	/** true: durch Umgebungsvariable festgelegt oder nicht ueber das Dashboard aenderbar. */
	locked: boolean;
	value: ConfigValue;
	restartPending: boolean;
	/** Additiv: erlaubte Werte bei `enum`, falls der Server sie nennt. */
	choices?: string[] | null;
}

export interface ConfigList {
	revision: number;
	entries: ConfigEntry[];
}

export const AUDIT_ACTIONS = [
	'set',
	'reset',
	'restart',
	'login',
	'setup',
	'reset_cli',
	'device_pair',
	'device_unpair',
	'device_action',
	'push_pause',
	'cache_clear',
	'cache_refresh',
	'device_pairing_open',
	'device_pairing_close'
] as const;
export type AuditAction = (typeof AUDIT_ACTIONS)[number];

export interface AuditEntry {
	id: number;
	at: string;
	/** Offene Aufzaehlung: unbekannte Aktionen werden unveraendert angezeigt. */
	action: AuditAction | (string & {});
	configKey: string | null;
	oldValue: string | null;
	newValue: string | null;
	/** Erste 8 Hexzeichen von SHA-256(Kopplungs-ID); nie die ID selbst. */
	deviceRef: string | null;
	/** Z. B. `test:delivered`. */
	outcome: string | null;
}

export interface AuditList {
	entries: AuditEntry[];
}

export interface ReplicaState {
	/** 8 Hexzeichen eines SHA-256, kein Hostname. */
	id: string;
	appliedGeneration: number;
	startedAt: string;
	state: 'current' | 'waiting' | (string & {});
}

export interface RestartState {
	generation: number;
	/** Schluessel mit apply = restart, deren Wert vom laufenden Prozess abweicht. */
	pending: string[];
	replicas: ReplicaState[];
}

// ---------------------------------------------------------------- Fehler

export type ApiErrorCode =
	| 'unauthorized'
	| 'forbidden'
	| 'not_found'
	| 'conflict'
	| 'validation'
	| 'rate_limited'
	| 'unavailable'
	| 'network'
	| 'timeout'
	| 'unknown';

export class ApiError extends Error {
	constructor(
		readonly status: number,
		readonly code: ApiErrorCode,
		message: string,
		/** Sekunden aus dem Retry-After-Header (429), sonst null. */
		readonly retryAfter: number | null = null,
		/** Fehlercode des Servers ({"error":"<code>"}), z. B. code_unknown; null wenn keiner kam. */
		readonly serverCode: string | null = null
	) {
		super(message);
		this.name = 'ApiError';
	}
}

export function codeFor(status: number): ApiErrorCode {
	switch (status) {
		case 401:
			return 'unauthorized';
		case 403:
			return 'forbidden';
		case 404:
			return 'not_found';
		case 409:
			return 'conflict';
		case 400:
		case 422:
			return 'validation';
		case 429:
			return 'rate_limited';
		case 502:
		case 503:
		case 504:
			return 'unavailable';
		default:
			return 'unknown';
	}
}

/** Text nach Servercode (bevorzugt), sonst nach Status. Der Server sendet nie Klartext. */
export function messageFor(status: number, serverCode: string | null): string {
	if (serverCode && errorText[serverCode]) return errorText[serverCode];
	const byStatus = errorText[codeFor(status)];
	return byStatus ?? `Fehler ${status}.`;
}

/** Retry-After als ganze Sekunden (nur positive Zahlen), sonst null. */
export function parseRetryAfter(value: string | null): number | null {
	if (value === null || value.trim() === '') return null;
	const n = Number(value);
	return Number.isFinite(n) && n > 0 ? Math.ceil(n) : null;
}

// ---------------------------------------------------------------- Client

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface ApiClientOptions {
	fetch?: FetchLike;
	baseUrl?: string;
	/** Abbruch nach so vielen Millisekunden (Standard 20 s); verhindert haengende Anfragen. */
	timeoutMs?: number;
}

/**
 * Typisierter Client. Das CSRF-Token liegt nur im Speicher dieser Instanz
 * (nie in Cookie oder localStorage) und wird bei Schreibzugriffen als X-CSRF-Token gesendet.
 */
export class ApiClient {
	private csrf: string | null = null;
	private readonly doFetch: FetchLike;
	private readonly baseUrl: string;
	private readonly timeoutMs: number;

	constructor(options: ApiClientOptions = {}) {
		this.doFetch = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
		this.baseUrl = options.baseUrl ?? '/dash/api';
		this.timeoutMs = options.timeoutMs ?? 20_000;
	}

	setCsrfToken(token: string | null): void {
		this.csrf = token;
	}

	private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
		const headers: Record<string, string> = { Accept: 'application/json' };
		const write = method !== 'GET';
		if (write) {
			headers['Content-Type'] = 'application/json';
			if (this.csrf) headers['X-CSRF-Token'] = this.csrf;
		}
		let res: Response;
		try {
			res = await this.doFetch(this.baseUrl + path, {
				method,
				headers,
				credentials: 'same-origin',
				cache: 'no-store',
				referrerPolicy: 'no-referrer',
				body: write && body !== undefined ? JSON.stringify(body) : undefined,
				signal:
					typeof AbortSignal.timeout === 'function'
						? AbortSignal.timeout(this.timeoutMs)
						: undefined
			});
		} catch (e) {
			if (e instanceof DOMException && (e.name === 'TimeoutError' || e.name === 'AbortError'))
				throw new ApiError(0, 'timeout', errorText.timeout);
			throw new ApiError(0, 'network', errorText.network);
		}
		if (!res.ok) {
			let serverCode: string | null = null;
			try {
				const data = (await res.json()) as { error?: unknown };
				if (typeof data.error === 'string') serverCode = data.error;
			} catch {
				/* Fehlerantworten duerfen leer sein (z. B. 403 ohne Details). */
			}
			throw new ApiError(
				res.status,
				codeFor(res.status),
				messageFor(res.status, serverCode),
				parseRetryAfter(res.headers.get('Retry-After')),
				serverCode
			);
		}
		if (res.status === 204) return undefined as T;
		try {
			return (await res.json()) as T;
		} catch {
			throw new ApiError(res.status, 'unknown', errorText.bad_response);
		}
	}

	/** Generischer Zugriff fuer die Insights-Schicht (src/lib/insights/api.ts); Pfad relativ zu /dash/api. */
	get<T>(path: string) {
		return this.request<T>('GET', path);
	}
	post<T>(path: string, body: unknown = {}) {
		return this.request<T>('POST', path, body);
	}
	put<T>(path: string, body: unknown = {}) {
		return this.request<T>('PUT', path, body);
	}
	delete<T>(path: string) {
		return this.request<T>('DELETE', path);
	}

	// Sitzung
	async session(): Promise<SessionState> {
		const s = await this.request<SessionState>('GET', '/session');
		this.csrf = s.state === 'authenticated' ? s.csrfToken : null;
		return s;
	}
	setupBegin() {
		return this.request<BeginResponse<CreationOptionsJSON>>('POST', '/setup/begin', {});
	}
	/** Antwort 204 mit Set-Cookie; danach GET session aufrufen. */
	setupFinish(challengeId: string, credential: AttestationCredentialJSON) {
		return this.request<void>('POST', '/setup/finish', { challengeId, credential });
	}
	loginBegin() {
		return this.request<BeginResponse<RequestOptionsJSON>>('POST', '/login/begin', {});
	}
	loginFinish(challengeId: string, credential: AssertionCredentialJSON) {
		return this.request<void>('POST', '/login/finish', { challengeId, credential });
	}
	async logout(): Promise<void> {
		await this.request<void>('POST', '/logout', {});
		this.csrf = null;
	}

	// Konfiguration: Werte werden typisiert gesendet (Zahl, Wahrheitswert, Text, Liste).
	config() {
		return this.request<ConfigList>('GET', '/config');
	}
	async setConfig(key: string, value: ConfigValue): Promise<ConfigEntry> {
		const r = await this.request<{ entry: ConfigEntry }>(
			'PUT',
			`/config/${encodeURIComponent(key)}`,
			{ value }
		);
		return r.entry;
	}
	async resetConfig(key: string): Promise<ConfigEntry> {
		const r = await this.request<{ entry: ConfigEntry }>(
			'DELETE',
			`/config/${encodeURIComponent(key)}`
		);
		return r.entry;
	}
	/** `limit` 1 bis 200; `action` filtert serverseitig. Es gibt keine Seitenverschiebung. */
	audit(limit = 200, action?: string) {
		const q = new URLSearchParams({ limit: String(limit) });
		if (action) q.set('action', action);
		return this.request<AuditList>('GET', `/config/audit?${q}`);
	}

	// Neustart
	restartState() {
		return this.request<RestartState>('GET', '/restart');
	}
	/** Sitzung und CSRF genuegen; die Bestaetigung fragt die Oberflaeche ab. Antwort 202. */
	requestRestart() {
		return this.request<{ generation: number }>('POST', '/restart', {});
	}
}
