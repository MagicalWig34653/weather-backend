/**
 * API-Vertrag des Dashboards (docs/dashboard-plan.md, Abschnitt 2.2).
 * Alle Routen liegen unter /dash/api, sind JSON-only und liefern Cache-Control: no-store.
 * Die endgueltigen Antwortformen werden in docs-site/content/dashboard-api.md (WP5)
 * festgeschrieben; Abweichungen sind dort und hier gemeinsam anzupassen.
 */

// ---------------------------------------------------------------- Sitzung

export interface CredentialInfo {
	/** Anzeigename des Passkeys (kein Personenbezug). */
	name: string;
	/** ISO-8601-Zeitpunkt der Registrierung; so faellt eine Fremdregistrierung auf. */
	created_at: string;
}

export type SessionState =
	| { state: 'setup_open'; minutes_left: number }
	| { state: 'login' }
	| { state: 'authenticated'; csrf_token: string; credential: CredentialInfo };

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
	excludeCredentials?: CredentialDescriptorJSON[];
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
	challenge_id: string;
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

// ---------------------------------------------------------------- Statistik

export interface HitCounts {
	hits: number;
	misses: number;
	/** hits / (hits + misses), 0 bis 1; null ohne Anfragen. */
	ratio: number | null;
}

export interface LayerStatus {
	id: string;
	name: string;
	status: 'ok' | 'stale' | 'missing';
	/** ISO-8601 des juengsten Slots; null wenn keiner vorhanden ist. */
	updated_at: string | null;
}

export interface StatsOverview {
	generated_at: string;
	/** Zaehler werden gesammelt geschrieben: Anzeige kann bis zu so viele Sekunden nachlaufen. */
	lag_seconds: number;
	cache_today: HitCounts;
	cache_30d: HitCounts;
	requests_today: number;
	gauges: { installations: number; subscriptions: number; regions_cells: number };
	layers: LayerStatus[];
}

export type StatusClass = '2xx' | '3xx' | '4xx' | '5xx';
export type DailyMetric = 'requests' | 'bytes';

export interface DailyPoint {
	/** Kalendertag YYYY-MM-DD (UTC). */
	date: string;
	/** Wert je Route (normalisierte Routenvorlage, keine Parameterwerte). */
	routes: Record<string, number>;
	/** Wert je Statusklasse. */
	status: Record<StatusClass, number>;
	not_modified: number;
	rate_limited: number;
}

export interface StatsDaily {
	metric: DailyMetric;
	days: DailyPoint[];
}

// ---------------------------------------------------------------- Konfiguration

/** Typname des Registers (ConfigRegistry.swift): int, number, text, url, bool, layers, choice, secret. */
export type ConfigType =
	'int' | 'number' | 'text' | 'url' | 'bool' | 'layers' | 'choice' | 'secret';
export type ConfigSource = 'env' | 'dashboard' | 'default';
/** live: wirkt nach hoechstens 30 s; restart: erst nach Neustart; envOnly: nur per Umgebungsvariable. */
export type ConfigApply = 'live' | 'restart' | 'envOnly';

/** Eintrag von GET /dash/api/config, Feldnamen wie `ConfigEntry` im Backend (camelCase, Werte als Text). */
export interface ConfigEntry {
	key: string;
	group: string;
	type: ConfigType;
	unit?: string | null;
	summary: string;
	apply: ConfigApply;
	/** Geheimnis: value ist immer null, nie anzeigen oder speichern. */
	secret: boolean;
	/** false bei Geheimnissen und envOnly-Schluesseln. */
	editable: boolean;
	source: ConfigSource;
	/** true: durch Umgebungsvariable festgelegt, nicht aenderbar. */
	lockedByEnv: boolean;
	value: string | null;
	defaultValue: string | null;
	isSet?: boolean | null;
	minimum?: number | null;
	maximum?: number | null;
	maxLength?: number | null;
	choices?: string[] | null;
	restartPending: boolean;
}

export interface ConfigList {
	entries: ConfigEntry[];
}

export type AuditAction = 'set' | 'reset' | 'restart' | 'login' | 'setup' | 'dashboard-reset';

export interface AuditEntry {
	id: number;
	at: string;
	action: AuditAction;
	key: string | null;
	/** Werte ohne Geheimnisse; null wenn nicht zutreffend. */
	old_value: string | null;
	new_value: string | null;
	actor: 'operator' | 'system';
}

export interface AuditList {
	entries: AuditEntry[];
}

export interface ReplicaState {
	slot: number;
	applied_generation: number;
	state: 'running' | 'waiting' | 'restarting';
}

export interface RestartState {
	generation: number;
	replicas: ReplicaState[];
	/** Schluessel mit apply = restart, deren Wert vom laufenden Prozess abweicht. */
	pending_keys: string[];
}

// ---------------------------------------------------------------- Fehler

export type ApiErrorCode =
	| 'unauthorized'
	| 'forbidden'
	| 'not_found'
	| 'conflict'
	| 'validation'
	| 'rate_limited'
	| 'network'
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

function codeFor(status: number): ApiErrorCode {
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
		default:
			return 'unknown';
	}
}

// ---------------------------------------------------------------- Client

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface ApiClientOptions {
	fetch?: FetchLike;
	baseUrl?: string;
}

/**
 * Typisierter Client. Das CSRF-Token liegt nur im Speicher dieser Instanz
 * (nie in Cookie oder localStorage) und wird bei Schreibzugriffen als X-CSRF-Token gesendet.
 */
export class ApiClient {
	private csrf: string | null = null;
	private readonly doFetch: FetchLike;
	private readonly baseUrl: string;

	constructor(options: ApiClientOptions = {}) {
		this.doFetch = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
		this.baseUrl = options.baseUrl ?? '/dash/api';
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
				body: write && body !== undefined ? JSON.stringify(body) : undefined
			});
		} catch {
			throw new ApiError(0, 'network', 'Der Server ist nicht erreichbar.');
		}
		if (!res.ok) {
			let message = '';
			let serverCode: string | null = null;
			try {
				const data = (await res.json()) as { message?: unknown; error?: unknown };
				if (typeof data.message === 'string') message = data.message;
				if (typeof data.error === 'string') serverCode = data.error;
			} catch {
				/* Fehlerantworten duerfen leer sein (z. B. 403 ohne Details). */
			}
			const ra = Number(res.headers.get('Retry-After'));
			throw new ApiError(
				res.status,
				codeFor(res.status),
				message || `Fehler ${res.status}`,
				Number.isFinite(ra) && ra > 0 ? ra : null,
				serverCode
			);
		}
		if (res.status === 204) return undefined as T;
		return (await res.json()) as T;
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
		this.csrf = s.state === 'authenticated' ? s.csrf_token : null;
		return s;
	}
	setupBegin() {
		return this.request<BeginResponse<CreationOptionsJSON>>('POST', '/setup/begin', {});
	}
	setupFinish(challengeId: string, credential: AttestationCredentialJSON) {
		return this.request<void>('POST', '/setup/finish', {
			challenge_id: challengeId,
			credential
		});
	}
	loginBegin() {
		return this.request<BeginResponse<RequestOptionsJSON>>('POST', '/login/begin', {});
	}
	loginFinish(challengeId: string, credential: AssertionCredentialJSON) {
		return this.request<void>('POST', '/login/finish', {
			challenge_id: challengeId,
			credential
		});
	}
	async logout(): Promise<void> {
		await this.request<void>('POST', '/logout', {});
		this.csrf = null;
	}

	// Statistik
	overview() {
		return this.request<StatsOverview>('GET', '/stats/overview');
	}
	daily(metric: DailyMetric, days = 30) {
		return this.request<StatsDaily>(
			'GET',
			`/stats/daily?days=${encodeURIComponent(days)}&metric=${encodeURIComponent(metric)}`
		);
	}

	// Konfiguration
	config() {
		return this.request<ConfigList>('GET', '/config');
	}
	setConfig(key: string, value: string) {
		return this.request<ConfigEntry>('PUT', `/config/${encodeURIComponent(key)}`, { value });
	}
	resetConfig(key: string) {
		return this.request<ConfigEntry>('DELETE', `/config/${encodeURIComponent(key)}`);
	}
	audit(limit = 100) {
		return this.request<AuditList>('GET', `/config/audit?limit=${encodeURIComponent(limit)}`);
	}

	// Neustart
	restartState() {
		return this.request<RestartState>('GET', '/restart');
	}
	/** Der Server verlangt die ausdrueckliche Bestaetigung zusaetzlich zu Sitzung und CSRF-Token. */
	requestRestart() {
		return this.request<RestartState>('POST', '/restart', { confirm: true });
	}
}
