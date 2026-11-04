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
		defaultValue: '6',
		minimum: 1,
		maximum: 48,
		unit: 'Stunden',
		summary: 'Länge der Radar-Historie, die vorgehalten wird.',
		apply: 'live',
		editable: true,
		secret: false,
		source: 'dashboard',
		lockedByEnv: false,
		value: '8',
		restartPending: false
	},
	{
		key: 'LAYERS',
		group: 'Radar',
		type: 'layers',
		defaultValue: 'radar',
		summary: 'Aktivierte Zusatzebenen, kommagetrennt.',
		apply: 'restart',
		editable: true,
		secret: false,
		source: 'env',
		lockedByEnv: true,
		value: 'radar,pressure,lightning',
		restartPending: false
	},
	{
		key: 'FETCH_WORKERS',
		group: 'Radar',
		type: 'int',
		defaultValue: '2',
		minimum: 1,
		maximum: 8,
		summary: 'Parallele Abrufe beim DWD.',
		apply: 'live',
		editable: true,
		secret: false,
		source: 'default',
		lockedByEnv: false,
		value: '2',
		restartPending: false
	},
	{
		key: 'CACHE_MAX_MB',
		group: 'Cache',
		type: 'int',
		defaultValue: '128',
		minimum: 16,
		maximum: 2048,
		unit: 'MB',
		summary: 'Größe des Arbeitsspeicher-Caches je Replikat.',
		apply: 'restart',
		editable: true,
		secret: false,
		source: 'dashboard',
		lockedByEnv: false,
		value: '256',
		restartPending: true
	},
	{
		key: 'APNS_ENV',
		group: 'Push',
		type: 'choice',
		defaultValue: 'production',
		choices: ['sandbox', 'production', 'both'],
		summary: 'Umgebung(en) für APNs.',
		apply: 'restart',
		editable: true,
		secret: false,
		source: 'default',
		lockedByEnv: false,
		value: 'production',
		restartPending: false
	},
	{
		key: 'DB_HOST',
		group: 'Datenbank',
		type: 'text',
		defaultValue: null,
		summary: 'Datenbank-Host. Nur per Umgebungsvariable.',
		apply: 'envOnly',
		editable: false,
		secret: false,
		source: 'env',
		lockedByEnv: true,
		value: 'db.example.internal',
		restartPending: false
	},
	{
		key: 'APNS_KEY',
		group: 'Push',
		type: 'secret',
		defaultValue: null,
		summary: 'APNs-Schlüssel. Geheimnis, nur per Umgebungsvariable.',
		apply: 'envOnly',
		editable: false,
		secret: true,
		source: 'env',
		lockedByEnv: true,
		value: null,
		isSet: true,
		restartPending: false
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
			key: 'CACHE_MAX_MB',
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
		pending_keys: config.filter((c) => c.restartPending).map((c) => c.key)
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
			config = config.map((c) => ({ ...c, restartPending: false }));
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
			if (!entry.editable) return json({ message: 'Nicht änderbar.' }, 403);
			if (entry.lockedByEnv) return json({ message: 'Durch Umgebungsvariable festgelegt.' }, 409);
			if (method === 'PUT') {
				const v = String(body.value ?? '');
				if (entry.type === 'int') {
					const n = Number(v);
					if (
						!/^-?\d+$/.test(v) ||
						n < (entry.minimum ?? -Infinity) ||
						n > (entry.maximum ?? Infinity)
					) {
						return json(
							{ message: `Erlaubt sind ganze Zahlen von ${entry.minimum} bis ${entry.maximum}.` },
							422
						);
					}
				}
				if (entry.type === 'choice' && !entry.choices?.includes(v)) {
					return json({ message: 'Ungültige Auswahl.' }, 422);
				}
				const old = String(entry.value);
				entry.value = v;
				entry.source = 'dashboard';
				if (entry.apply === 'restart') entry.restartPending = true;
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
				entry.value = entry.defaultValue;
				entry.source = 'default';
				if (entry.apply === 'restart') entry.restartPending = true;
				audit.unshift({
					id: audit.length + 1,
					at: new Date().toISOString(),
					action: 'reset',
					key: entry.key,
					old_value: old,
					new_value: String(entry.defaultValue),
					actor: 'operator'
				});
				return json(entry);
			}
		}
		return json({ message: 'Nicht gefunden.' }, 404);
	};
}
