/**
 * Mock-Backend fuer die Entwicklung (nur mit VITE_MOCK=1, z. B. `npm run dev:mock`).
 * Enthaelt ausschliesslich erfundene Platzhalterdaten. Wird im Produktionsbuild
 * nicht eingebunden (dynamischer Import hinter einer Build-Konstante).
 */
import type {
	AuditEntry,
	ConfigEntry,
	DailyPoint,
	RestartState,
	SessionState,
	StatsOverview
} from './api';

type Mode = 'setup' | 'login' | 'auth';

function initialMode(): Mode {
	const m =
		typeof location !== 'undefined' ? new URLSearchParams(location.search).get('mock') : null;
	return m === 'setup' || m === 'login' ? m : 'auth';
}

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function seeded(i: number): number {
	const x = Math.sin(i * 12.9898) * 43758.5453;
	return x - Math.floor(x);
}

function buildDays(): DailyPoint[] {
	const days: DailyPoint[] = [];
	const today = new Date(Date.UTC(2026, 10, 3));
	for (let i = 29; i >= 0; i--) {
		const d = new Date(today.getTime() - i * 86400000);
		const base = 52000 + Math.round(seeded(i) * 14000) + (29 - i) * 700;
		const radar = Math.round(base * 0.62);
		const status = Math.round(base * 0.2);
		const push = Math.round(base * 0.1);
		const rest = base - radar - status - push;
		const e4 = Math.round(base * 0.012 * (0.5 + seeded(i + 40)));
		const e5 = Math.round(base * 0.0008 * seeded(i + 80));
		const e3 = Math.round(base * 0.31);
		days.push({
			date: d.toISOString().slice(0, 10),
			routes: {
				'/v1/radar/:layer/:slot': radar,
				'/v1/status': status,
				'/v1/push/regions': push,
				'/v1/installations': rest
			},
			status: { '2xx': base - e3 - e4 - e5, '3xx': e3, '4xx': e4, '5xx': e5 },
			not_modified: e3,
			rate_limited: Math.round(e4 * 0.3)
		});
	}
	return days;
}

const sampleConfig: ConfigEntry[] = [
	{
		key: 'HISTORY_HOURS',
		group: 'Radar',
		type: 'int',
		default: 6,
		min: 1,
		max: 48,
		unit: 'Stunden',
		description: 'Länge der Radar-Historie, die vorgehalten wird.',
		apply: 'live',
		source: 'dashboard',
		locked: false,
		value: 8,
		restart_pending: false
	},
	{
		key: 'LAYERS',
		group: 'Radar',
		type: 'list',
		default: 'radar',
		min: null,
		max: null,
		unit: null,
		description: 'Aktivierte Zusatzebenen, kommagetrennt.',
		apply: 'restart',
		source: 'env',
		locked: true,
		value: 'radar,pressure,lightning',
		restart_pending: false
	},
	{
		key: 'RATE_LIMIT_PER_MINUTE',
		group: 'Schutz',
		type: 'int',
		default: 120,
		min: 10,
		max: 2000,
		unit: 'pro Minute',
		description: 'Anfragen je Installation und Minute, bevor 429 geantwortet wird.',
		apply: 'live',
		source: 'default',
		locked: false,
		value: 120,
		restart_pending: false
	},
	{
		key: 'LRU_CACHE_MB',
		group: 'Cache',
		type: 'int',
		default: 128,
		min: 16,
		max: 2048,
		unit: 'MB',
		description: 'Größe des Arbeitsspeicher-Caches je Replikat.',
		apply: 'restart',
		source: 'dashboard',
		locked: false,
		value: 256,
		restart_pending: true
	},
	{
		key: 'PUSH_ENABLED',
		group: 'Push',
		type: 'bool',
		default: false,
		min: null,
		max: null,
		unit: null,
		description: 'Schaltet den optionalen Pushdienst ein.',
		apply: 'restart',
		source: 'default',
		locked: false,
		value: false,
		restart_pending: false
	},
	{
		key: 'APNS_KEY',
		group: 'Push',
		type: 'string',
		default: null,
		min: null,
		max: null,
		unit: null,
		description: 'APNs-Schlüssel. Geheimnis, nur per Umgebungsvariable.',
		apply: 'restart',
		source: 'env',
		locked: true,
		value: null,
		restart_pending: false,
		secret: true
	}
];

export function createMockFetch() {
	let mode = initialMode();
	let config = structuredClone(sampleConfig);
	let generation = 4;
	let restarting = false;
	const audit: AuditEntry[] = [
		{
			id: 3,
			at: '2026-11-03T08:12:00Z',
			action: 'set',
			key: 'LRU_CACHE_MB',
			old_value: '128',
			new_value: '256',
			actor: 'operator'
		},
		{
			id: 2,
			at: '2026-11-02T19:40:00Z',
			action: 'set',
			key: 'HISTORY_HOURS',
			old_value: '6',
			new_value: '8',
			actor: 'operator'
		},
		{
			id: 1,
			at: '2026-11-02T19:31:00Z',
			action: 'setup',
			key: null,
			old_value: null,
			new_value: null,
			actor: 'operator'
		}
	];
	const days = buildDays();

	const restartState = (): RestartState => ({
		generation,
		replicas: restarting
			? [
					{ slot: 1, applied_generation: generation, state: 'running' },
					{ slot: 2, applied_generation: generation - 1, state: 'waiting' }
				]
			: [
					{ slot: 1, applied_generation: generation, state: 'running' },
					{ slot: 2, applied_generation: generation, state: 'running' }
				],
		pending_keys: config.filter((c) => c.restart_pending).map((c) => c.key)
	});

	return async function mockFetch(input: string, init: RequestInit = {}): Promise<Response> {
		await new Promise((r) => setTimeout(r, 120));
		const url = new URL(input, 'http://mock.invalid');
		const path = url.pathname.replace(/^\/dash\/api/, '');
		const method = init.method ?? 'GET';
		const body = typeof init.body === 'string' ? JSON.parse(init.body) : {};

		if (path === '/session') {
			const s: SessionState =
				mode === 'setup'
					? { state: 'setup_open', minutes_left: 12 }
					: mode === 'login'
						? { state: 'login' }
						: {
								state: 'authenticated',
								csrf_token: 'mock-csrf-token',
								credential: { name: 'Passkey des Betreibers', created_at: '2026-11-02T19:31:00Z' }
							};
			return json(s);
		}
		if (path === '/setup/begin' || path === '/login/begin') {
			return json({
				challenge_id: 'mock',
				options: { challenge: 'bW9jaw', rp: { id: 'localhost', name: 'Showers Dashboard' } }
			});
		}
		if (path === '/setup/finish' || path === '/login/finish') {
			mode = 'auth';
			return new Response(null, { status: 204 });
		}
		if (mode !== 'auth') return json({ message: 'Nicht angemeldet.' }, 401);
		if (
			method !== 'GET' &&
			(init.headers as Record<string, string>)['X-CSRF-Token'] !== 'mock-csrf-token'
		) {
			return json({}, 403);
		}
		if (path === '/logout') {
			mode = 'login';
			return new Response(null, { status: 204 });
		}
		if (path === '/stats/overview') {
			const o: StatsOverview = {
				generated_at: '2026-11-03T21:14:30Z',
				lag_seconds: 60,
				cache_today: { hits: 41873, misses: 2204, ratio: 41873 / (41873 + 2204) },
				cache_30d: { hits: 1388215, misses: 91402, ratio: 1388215 / (1388215 + 91402) },
				requests_today: 62110,
				gauges: { installations: 1284, subscriptions: 2310, regions_cells: 48120 },
				layers: [
					{
						id: 'radar',
						name: 'Niederschlagsradar',
						status: 'ok',
						updated_at: '2026-11-03T21:10:00Z'
					},
					{ id: 'pressure', name: 'Luftdruck', status: 'ok', updated_at: '2026-11-03T21:00:00Z' },
					{ id: 'lightning', name: 'Blitze', status: 'stale', updated_at: '2026-11-03T20:20:00Z' },
					{ id: 'clouds', name: 'Wolken', status: 'missing', updated_at: null }
				]
			};
			return json(o);
		}
		if (path === '/stats/daily') {
			const metric = url.searchParams.get('metric') === 'bytes' ? 'bytes' : 'requests';
			const n = Math.min(30, Number(url.searchParams.get('days') ?? 30) || 30);
			const scale = metric === 'bytes' ? 18000 : 1;
			const sliced = days.slice(-n).map((d) => ({
				...d,
				routes: Object.fromEntries(Object.entries(d.routes).map(([k, v]) => [k, v * scale])),
				status: Object.fromEntries(Object.entries(d.status).map(([k, v]) => [k, v * scale]))
			}));
			return json({ metric, days: sliced });
		}
		if (path === '/config') return json({ entries: config });
		if (path === '/config/audit') return json({ entries: audit });
		if (path === '/restart' && method === 'GET') return json(restartState());
		if (path === '/restart' && method === 'POST') {
			if (body.confirm !== true) return json({ message: 'Bestätigung fehlt.' }, 400);
			generation++;
			restarting = true;
			config = config.map((c) => ({ ...c, restart_pending: false }));
			audit.unshift({
				id: audit.length + 1,
				at: new Date().toISOString(),
				action: 'restart',
				key: null,
				old_value: String(generation - 1),
				new_value: String(generation),
				actor: 'operator'
			});
			setTimeout(() => (restarting = false), 4000);
			return json(restartState());
		}
		const m = path.match(/^\/config\/([A-Z0-9_]+)$/);
		if (m) {
			const entry = config.find((c) => c.key === m[1]);
			if (!entry) return json({ message: 'Unbekannter Schlüssel.' }, 404);
			if (entry.locked) return json({ message: 'Durch Umgebungsvariable festgelegt.' }, 409);
			if (method === 'PUT') {
				const v = body.value;
				if (entry.type === 'int') {
					if (!Number.isInteger(v) || v < (entry.min ?? -Infinity) || v > (entry.max ?? Infinity)) {
						return json(
							{ message: `Erlaubt sind ganze Zahlen von ${entry.min} bis ${entry.max}.` },
							422
						);
					}
				}
				const old = String(entry.value);
				entry.value = v;
				entry.source = 'dashboard';
				if (entry.apply === 'restart') entry.restart_pending = true;
				audit.unshift({
					id: audit.length + 1,
					at: new Date().toISOString(),
					action: 'set',
					key: entry.key,
					old_value: old,
					new_value: String(v),
					actor: 'operator'
				});
				return json(entry);
			}
			if (method === 'DELETE') {
				const old = String(entry.value);
				entry.value = entry.default;
				entry.source = 'default';
				if (entry.apply === 'restart') entry.restart_pending = true;
				audit.unshift({
					id: audit.length + 1,
					at: new Date().toISOString(),
					action: 'reset',
					key: entry.key,
					old_value: old,
					new_value: String(entry.default),
					actor: 'operator'
				});
				return json(entry);
			}
		}
		return json({ message: 'Nicht gefunden.' }, 404);
	};
}
