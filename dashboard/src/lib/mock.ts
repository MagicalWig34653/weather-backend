/**
 * Mock-Backend fuer die Entwicklung (nur `npm run dev:mock`, Build-Konstante __MOCK__).
 * Enthaelt ausschliesslich erfundene Platzhalterdaten im Wire-Format des Vertrags
 * (docs-site/content/dashboard-api.md). Wird im Produktionsbuild nicht eingebunden.
 *
 * URL-Schalter: ?mock=setup|closed|login|auth (Sitzung), ?mockstate=empty|slice1|error|slow|limited|pairopen|pairending.
 */
import type { AuditEntry, ConfigEntry, ConfigValue, RestartState, SessionState } from './api';
import { validateValue } from './config/form';

type Mode = 'setup' | 'closed' | 'login' | 'auth';

const param = (name: string): string | null =>
	typeof location !== 'undefined' ? new URLSearchParams(location.search).get(name) : null;

function initialMode(): Mode {
	const m = param('mock');
	return m === 'setup' || m === 'closed' || m === 'login' ? m : 'auth';
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json', ...headers }
	});
}
const err = (status: number, error: string, headers: Record<string, string> = {}) =>
	json({ error }, status, headers);

function entry(
	e: Partial<ConfigEntry> & Pick<ConfigEntry, 'key' | 'group' | 'type' | 'description'>
): ConfigEntry {
	return {
		default: null,
		min: null,
		max: null,
		unit: null,
		apply: 'live',
		source: 'default',
		locked: false,
		value: e.default ?? null,
		restartPending: false,
		...e
	};
}

const warn = (
	rule: string,
	description: string,
	type: 'int' | 'double',
	yellow: number,
	red: number,
	min: number,
	max: number,
	unit: string | null = null
): ConfigEntry[] => [
	entry({
		key: `DASH_WARN_${rule}_YELLOW`,
		group: 'Dashboard-Schwellen',
		type,
		description: `${description} (Warnung)`,
		default: yellow,
		min,
		max,
		unit
	}),
	entry({
		key: `DASH_WARN_${rule}_RED`,
		group: 'Dashboard-Schwellen',
		type,
		description: `${description} (kritisch)`,
		default: red,
		min,
		max,
		unit
	})
];

const sampleConfig = (): ConfigEntry[] => [
	entry({
		key: 'HISTORY_HOURS',
		group: 'Radar',
		type: 'int',
		description: 'Länge der Radar-Historie, die vorgehalten wird.',
		default: 6,
		min: 1,
		max: 48,
		unit: 'Stunden',
		source: 'dashboard',
		value: 8
	}),
	entry({
		key: 'LAYERS',
		group: 'Radar',
		type: 'list',
		description: 'Aktivierte Zusatzebenen, kommagetrennt.',
		default: ['radar'],
		apply: 'restart',
		source: 'env',
		locked: true,
		value: ['radar', 'pressure', 'lightning']
	}),
	entry({
		key: 'FETCH_WORKERS',
		group: 'Radar',
		type: 'int',
		description: 'Parallele Abrufe beim DWD.',
		default: 2,
		min: 1,
		max: 8
	}),
	entry({
		key: 'AVAILABILITY_DELAY_SECONDS',
		group: 'Radar',
		type: 'double',
		description: 'Wartezeit nach dem Slot, bevor der DWD abgefragt wird.',
		default: 45.5,
		min: 0,
		max: 600,
		unit: 's'
	}),
	entry({
		key: 'USER_AGENT',
		group: 'Radar',
		type: 'string',
		description: 'Kennung gegenüber dem DWD.',
		default: 'showers-radar/1',
		apply: 'restart'
	}),
	entry({
		key: 'CACHE_MAX_MB',
		group: 'Cache',
		type: 'int',
		description: 'Größe des Arbeitsspeicher-Caches je Replikat.',
		default: 64,
		min: 8,
		max: 1024,
		unit: 'MB',
		apply: 'restart',
		source: 'dashboard',
		value: 128,
		restartPending: true
	}),
	entry({
		key: 'PUSH_ENABLED',
		group: 'Push',
		type: 'bool',
		description: 'Schaltet Registrierung und Versand von Push-Mitteilungen ein.',
		default: false,
		apply: 'restart',
		source: 'env',
		locked: true,
		value: true
	}),
	entry({
		key: 'PUSH_QUIET_HOURS',
		group: 'Push',
		type: 'bool',
		description: 'Mitteilungen nachts zurückhalten.',
		default: false
	}),
	entry({
		key: 'APNS_ENV',
		group: 'Push',
		type: 'enum',
		description: 'APNs-Umgebung: sandbox, production oder both.',
		default: 'production',
		apply: 'restart'
	}),
	entry({
		key: 'APNS_KEY_FILE',
		group: 'Push',
		type: 'string',
		description: 'Pfad des APNs-Schlüssels (Geheimnis, nur per Umgebungsvariable).',
		default: '',
		apply: 'restart',
		source: 'env',
		locked: true,
		value: null
	}),
	entry({
		key: 'DB_HOST',
		group: 'Datenbank',
		type: 'string',
		description: 'Datenbank-Host, nur per Umgebungsvariable.',
		default: '',
		apply: 'restart',
		source: 'env',
		locked: true,
		value: 'db.example.internal'
	}),
	entry({
		key: 'DASH_MIN_GROUP',
		group: 'Dashboard-Schwellen',
		type: 'int',
		description: 'k-Schwelle: kleinere Gruppen in Verteilungen werden unterdrückt.',
		default: 5,
		min: 3,
		max: 50
	}),
	...warn('LAYER_AGE_FACTOR', 'Ebene zu alt, Vielfaches des Takts', 'double', 2, 4, 1, 20),
	...warn('ERROR_RATE_5XX', 'Anteil der 5xx-Antworten', 'double', 0.005, 0.02, 0, 1),
	...warn(
		'OUTBOX_AGE_SECONDS',
		'Ältester Eintrag der Warteschlange',
		'int',
		120,
		600,
		10,
		86400,
		's'
	),
	...warn('APNS_REJECTION', 'Anteil abgelehnter APNs-Sendungen', 'double', 0.05, 0.25, 0, 1),
	...warn('TOKEN_INVALIDATION', 'Anteil ungültig gewordener Token', 'double', 0.05, 0.2, 0, 1),
	...warn('CACHE_HIT', 'Cache-Trefferquote (untere Grenze)', 'double', 0.8, 0.5, 0, 1),
	...warn('CAP_FILL', 'Füllgrad der Obergrenzen', 'double', 0.8, 0.95, 0, 1),
	...warn('LA_START_RATIO', 'Live-Activity-Start-Quote (untere Grenze)', 'double', 0.7, 0.3, 0, 1)
];

function sampleAudit(): AuditEntry[] {
	const base = Date.UTC(2026, 10, 6, 9, 30);
	const rows: Omit<AuditEntry, 'id' | 'at'>[] = [];
	const nul = { configKey: null, oldValue: null, newValue: null, deviceRef: null, outcome: null };
	const kinds: Omit<AuditEntry, 'id' | 'at'>[] = [
		{ ...nul, action: 'set', configKey: 'CACHE_MAX_MB', oldValue: '64', newValue: '128' },
		{ ...nul, action: 'device_action', deviceRef: '4be1c09a', outcome: 'test:delivered' },
		{ ...nul, action: 'login' },
		{ ...nul, action: 'reset', configKey: 'HISTORY_HOURS', oldValue: '8', newValue: '6' },
		{ ...nul, action: 'push_pause', newValue: 'true' },
		{ ...nul, action: 'cache_clear', outcome: 'all' },
		{
			...nul,
			action: 'set',
			configKey: 'DASH_WARN_CACHE_HIT_YELLOW',
			oldValue: '0.8',
			newValue: '0.85'
		},
		{ ...nul, action: 'device_pair', deviceRef: '4be1c09a' },
		{ ...nul, action: 'restart', oldValue: '3', newValue: '4' }
	];
	for (let i = 0; i < 64; i++) rows.push(kinds[i % kinds.length]);
	rows.push({ ...nul, action: 'reset_cli' }, { ...nul, action: 'setup' });
	return rows.map((r, i) => ({
		...r,
		id: rows.length - i,
		at: new Date(base - i * 5.5 * 3600_000).toISOString().replace(/\.\d+Z$/, 'Z')
	}));
}

export function createMockFetch() {
	let mode = initialMode();
	const state = param('mockstate');
	let config = sampleConfig();
	let generation = 4;
	let restartedAt = 0;
	let paused = false;
	const audit = sampleAudit();
	const log = (e: Omit<AuditEntry, 'id' | 'at'>) =>
		audit.unshift({
			id: (audit[0]?.id ?? 0) + 1,
			at: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
			...e
		});
	const nul = { configKey: null, oldValue: null, newValue: null, deviceRef: null, outcome: null };

	const restartState = (): RestartState => {
		const rolling = Date.now() - restartedAt < 5000;
		return {
			generation,
			pending: config.filter((c) => c.restartPending).map((c) => c.key),
			replicas: [
				{
					id: '9f2a41c7',
					appliedGeneration: generation,
					startedAt: '2026-11-05T21:02:11Z',
					state: 'current'
				},
				{
					id: '3be7d0a2',
					appliedGeneration: rolling ? generation - 1 : generation,
					startedAt: '2026-11-05T21:03:02Z',
					state: rolling ? 'waiting' : 'current'
				}
			]
		};
	};

	return async function mockFetch(input: string, init: RequestInit = {}): Promise<Response> {
		await new Promise((r) => setTimeout(r, 120));
		const url = new URL(input, 'http://mock.invalid');
		const path = url.pathname.replace(/^\/dash\/api/, '');
		const method = init.method ?? 'GET';
		const body = typeof init.body === 'string' ? JSON.parse(init.body) : {};

		if (path === '/session') {
			const s: SessionState =
				mode === 'setup'
					? { state: 'setupOpen', minutesLeft: 12 }
					: mode === 'closed'
						? { state: 'setupClosed' }
						: mode === 'login'
							? { state: 'login' }
							: {
									state: 'authenticated',
									csrfToken: 'mock-csrf-token',
									credential: { name: 'Passkey des Betreibers', createdAt: '2026-11-02T19:31:00Z' }
								};
			return json(s);
		}
		if (path === '/setup/begin' || path === '/login/begin') {
			if (mode === 'closed') return err(403, 'setup_closed');
			return json({
				challengeId: 'mock',
				options: { challenge: 'bW9jaw', rp: { id: 'localhost', name: 'Showers Dashboard' } }
			});
		}
		if (path === '/setup/finish' || path === '/login/finish') {
			mode = 'auth';
			return new Response(null, { status: 204 });
		}
		if (mode !== 'auth') return err(401, 'unauthorized');
		if (
			method !== 'GET' &&
			(init.headers as Record<string, string>)['X-CSRF-Token'] !== 'mock-csrf-token'
		) {
			return err(403, 'forbidden');
		}
		if (state === 'slow') await new Promise((r) => setTimeout(r, 4000));
		if (state === 'error') return err(503, 'data_unavailable');
		if (state === 'limited' && method !== 'GET')
			return err(429, path.includes('/actions/') ? 'action_rate_limited' : 'rate_limited', {
				'Retry-After': '42'
			});

		if (path === '/logout') {
			mode = 'login';
			return new Response(null, { status: 204 });
		}

		if (path === '/push/pause' && method === 'PUT') {
			paused = body.paused === true;
			log({ ...nul, action: 'push_pause', newValue: String(paused) });
			return json({
				paused,
				since: paused ? new Date().toISOString().replace(/\.\d+Z$/, 'Z') : null
			});
		}
		if (path === '/cache/clear' && method === 'POST') {
			log({ ...nul, action: 'cache_clear', outcome: String(body.layer ?? 'all') });
		}
		if (
			path.startsWith('/insights') ||
			path.startsWith('/devices') ||
			path === '/push/pause' ||
			path === '/cache/clear'
		) {
			if (path === '/devices/pairing' && method === 'POST') {
				const m = body.minutes;
				if (typeof m !== 'number' || !Number.isInteger(m) || m < 1 || m > 15)
					return err(400, 'validation');
				log({ ...nul, action: 'device_pairing_open' });
			}
			if (path === '/devices/pairing' && method === 'DELETE')
				log({ ...nul, action: 'device_pairing_close', outcome: 'manual' });
			if (path === '/devices/pair' && method === 'POST') {
				if (!/^[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}$/.test(String(body.code ?? '').trim()))
					return err(400, 'validation');
				if (String(body.code).toUpperCase().startsWith('XXXX')) return err(404, 'code_unknown');
				log({ ...nul, action: 'device_pair', deviceRef: '4be1c09a' });
				log({ ...nul, action: 'device_pairing_close', outcome: 'redeemed' });
			}
			const { mockInsights } = await import('./insights/mock');
			const mockState =
				state === 'empty' ||
				state === 'slice1' ||
				state === 'sparse' ||
				state === 'dayonly' ||
				state === 'pairopen' ||
				state === 'pairending'
					? state
					: 'normal';
			const out = mockInsights(path, method, url.searchParams, body, mockState) as
				Record<string, unknown> | null | undefined;
			if (out === null) return new Response(null, { status: 204 });
			if (out !== undefined) {
				if (path === '/insights/overview') out.pushPaused = paused;
				const created = path === '/devices/pair';
				const accepted = method === 'POST' && path.includes('/actions/');
				return json(out, created ? 201 : accepted ? 202 : 200);
			}
			return err(404, 'not_found');
		}

		if (path === '/config' && method === 'GET') return json({ revision: 12, entries: config });
		if (path === '/config/audit') {
			const limit = Number(url.searchParams.get('limit') ?? 50);
			const action = url.searchParams.get('action');
			if (!Number.isInteger(limit) || limit < 1 || limit > 200) return err(400, 'validation');
			const rows = audit.filter((a) => !action || a.action === action).slice(0, limit);
			return json({ entries: rows });
		}
		if (path === '/restart' && method === 'GET') return json(restartState());
		if (path === '/restart' && method === 'POST') {
			if (Date.now() - restartedAt < 60_000 && restartedAt > 0)
				return err(429, 'rate_limited', { 'Retry-After': '60' });
			generation++;
			restartedAt = Date.now();
			config = config.map((c) => ({ ...c, restartPending: false }));
			log({
				...nul,
				action: 'restart',
				oldValue: String(generation - 1),
				newValue: String(generation)
			});
			return json({ generation }, 202);
		}
		const m = path.match(/^\/config\/([A-Z0-9_]+)$/);
		if (m && (method === 'PUT' || method === 'DELETE')) {
			const e = config.find((c) => c.key === m[1]);
			if (!e) return err(404, 'not_found');
			if (e.locked) return err(409, 'locked_by_env');
			const old = e.value;
			let next: ConfigValue;
			if (method === 'PUT') {
				const v = validateValue(e, body.value as ConfigValue);
				if (!v.ok) return err(400, 'validation');
				next = v.value;
				e.source = 'dashboard';
			} else {
				next = e.default;
				e.source = 'default';
			}
			e.value = next;
			if (e.apply === 'restart') e.restartPending = true;
			const text = (v: ConfigValue) =>
				Array.isArray(v) ? v.join(',') : v === null ? null : String(v);
			log({
				...nul,
				action: method === 'PUT' ? 'set' : 'reset',
				configKey: e.key,
				oldValue: text(old),
				newValue: text(next)
			});
			return json({ entry: e });
		}
		return err(404, 'not_found');
	};
}
