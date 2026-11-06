/**
 * Erfundene Insights-Daten fuer Mock-Modus und Screenshots (nur mit VITE_MOCK=1 geladen).
 * Zustaende per URL: ?mockstate=empty | error | slow.
 */
import type {
	DeviceList,
	DistributionInsights,
	Finding,
	LinkedDevice,
	OpsInsights,
	OpsLayer,
	OverviewInsights,
	PushInsights,
	Range,
	RunStatus,
	TrafficInsights,
	Trend
} from './types';

const HOUR = 3600_000;
function rnd(i: number, salt = 0): number {
	const x = Math.sin((i + 1) * 12.9898 + salt * 78.233) * 43758.5453;
	return x - Math.floor(x);
}

function grid(range: Range): { t: string[]; hours: number } {
	const hours = range === '24h' ? 1 : range === '7d' ? 4 : 24;
	const count = range === '24h' ? 24 : range === '7d' ? 42 : 30;
	const end = Math.floor(Date.now() / (hours * HOUR)) * hours * HOUR;
	const t = Array.from({ length: count }, (_, i) =>
		new Date(end - (count - 1 - i) * hours * HOUR).toISOString()
	);
	return { t, hours };
}

/** Tagesgang: ruhige Nacht, Spitzen morgens und am fruehen Abend (UTC, naeherungsweise). */
function diurnal(iso: string): number {
	const d = new Date(iso);
	const h = d.getUTCHours();
	const wk = d.getUTCDay() === 0 || d.getUTCDay() === 6 ? 0.88 : 1;
	return (
		wk *
		(0.42 + 0.34 * Math.exp(-Math.pow((h - 6) / 3, 2)) + 0.5 * Math.exp(-Math.pow((h - 16) / 4, 2)))
	);
}

function series(t: string[], hours: number, perHour: number, salt: number, noise = 0.14): number[] {
	return t.map((x, i) =>
		Math.round(perHour * hours * diurnal(x) * (1 - noise / 2 + rnd(i, salt) * noise))
	);
}

const prevOf = (v: number[], f = 0.93): number => Math.round(v.reduce((s, x) => s + x, 0) * f);
const total = (a: number[]) => a.reduce((s, v) => s + v, 0);

function trend(values: number[], factor: number, valueOf?: number): Trend {
	return { value: valueOf ?? total(values), previous: prevOf(values, factor), series: values };
}

function routeTable(sum: number): TrafficInsights['routes'] {
	const rows: [string, number, number, number][] = [
		['/v1/radar/:layer/:slot', 0.56, 36000, 62],
		['/v1/status', 0.19, 1400, 9],
		['/v1/push/regions', 0.11, 8500, 38],
		['/v1/push/installations/:id', 0.09, 1400, 24],
		['/v1/layers', 0.05, 2400, 12]
	];
	return rows.map(([route, share, bytes, p95Ms]) => ({
		route,
		requests: Math.round(sum * share),
		bytes: Math.round(sum * share * bytes),
		p95Ms
	}));
}

export type MockState = 'normal' | 'empty' | 'error' | 'slow';

function pad(n: number, v = 0): number[] {
	return new Array<number>(n).fill(v);
}

function runs(salt: number, errorEvery: number, missed = 0): RunStatus[] {
	return Array.from({ length: 96 }, (_, i) => {
		if (i >= 96 - missed) return 'missed';
		if (errorEvery && rnd(i, salt) < 1 / errorEvery)
			return rnd(i, salt + 5) < 0.5 ? 'error' : 'missed';
		return 'ok';
	});
}

function layers(empty: boolean): OpsLayer[] {
	const now = Date.now();
	const iso = (min: number) => new Date(now - min * 60_000).toISOString();
	if (empty) return [];
	return [
		{
			id: 'radar',
			name: 'Niederschlagsradar',
			status: 'ok',
			lastRunAt: iso(3),
			delayP50Seconds: 142,
			delayP95Seconds: 231,
			runs: runs(1, 40)
		},
		{
			id: 'pressure',
			name: 'Luftdruck',
			status: 'ok',
			lastRunAt: iso(12),
			delayP50Seconds: 410,
			delayP95Seconds: 702,
			runs: runs(2, 0)
		},
		{
			id: 'lightning',
			name: 'Blitze',
			status: 'stale',
			lastRunAt: iso(52),
			delayP50Seconds: 95,
			delayP95Seconds: 1480,
			runs: runs(3, 12, 11)
		},
		{
			id: 'clouds',
			name: 'Wolken',
			status: 'missing',
			lastRunAt: null,
			delayP50Seconds: null,
			delayP95Seconds: null,
			runs: pad(96).map(() => 'none' as RunStatus)
		}
	];
}

function findings(empty: boolean): Finding[] {
	if (empty) return [];
	const now = Date.now();
	return [
		{
			id: 'layer-stale-lightning',
			severity: 'warn',
			title: 'Blitze: Ebene veraltet',
			detail:
				'Der letzte erfolgreiche Lauf liegt 52 Minuten zurück (Schwelle 30 Minuten). 11 der letzten 96 Läufe fehlen.',
			since: new Date(now - 52 * 60_000).toISOString(),
			href: '/betrieb'
		},
		{
			id: 'env-mismatch',
			severity: 'info',
			title: '80 Installationen in der Sandbox-Umgebung',
			detail: 'APNs läuft mit production; Sandbox-Installationen erhalten keine Mitteilungen.',
			since: new Date(now - 6 * HOUR).toISOString(),
			href: '/push'
		},
		{
			id: 'cache-ok',
			severity: 'ok',
			title: 'Cache-Quote über Ziel',
			detail: '94,8 % Treffer; Ziel ab 90 %.',
			since: new Date(now - 24 * HOUR).toISOString()
		}
	];
}

export function mockInsights(
	path: string,
	method: string,
	params: URLSearchParams,
	body: Record<string, unknown>,
	state: MockState
): unknown | undefined {
	const empty = state === 'empty';
	const range = (params.get('range') as Range) ?? '24h';
	const { t, hours } = grid(range);
	const n = t.length;
	const generatedAt = new Date().toISOString();

	if (path === '/insights/overview') {
		const req = empty ? pad(n) : series(t, hours, 2600, 1);
		const ratioSeries = empty
			? pad(n)
			: t.map((_, i) => Number((0.935 + rnd(i, 9) * 0.03).toFixed(3)));
		const delivery = empty
			? pad(n)
			: t.map((_, i) => Number((0.972 + rnd(i, 11) * 0.02).toFixed(3)));
		const act = empty
			? pad(n)
			: t.map((x, i) => Math.round(30 * diurnal(x) * (0.8 + rnd(i, 4) * 0.4)));
		const o: OverviewInsights = {
			t,
			generatedAt,
			lagSeconds: 60,
			findings: findings(empty),
			kpis: {
				requests: trend(req, 0.93),
				cacheRatio: {
					value: empty ? 0 : 0.948,
					previous: empty ? null : 0.941,
					series: ratioSeries
				},
				pushDeliveryRatio: {
					value: empty ? 0 : 0.981,
					previous: empty ? null : 0.984,
					series: delivery
				},
				activeActivities: { value: empty ? 0 : 27, previous: empty ? null : 22, series: act },
				ingestAgeSeconds: { value: empty ? 0 : 187, limit: 600 },
				installations: {
					value: empty ? 0 : 1284,
					previous: empty ? null : 1249,
					series: empty ? pad(n) : t.map((_, i) => 1180 + Math.round((i / n) * 104))
				}
			},
			layers: layers(empty).map((l) => ({
				id: l.id,
				name: l.name,
				status: l.status,
				updated_at: l.lastRunAt
			}))
		};
		return o;
	}

	if (path === '/insights/ops') {
		const req = empty ? pad(n) : series(t, hours, 2600, 1);
		const lookups = req.map((v) => Math.round(v * 0.72));
		const part = (f: number) =>
			lookups.map((v, i) => Math.round(v * f * (0.96 + rnd(i, 30 + f * 10) * 0.08)));
		const spike = Math.floor(n * 0.62);
		const o: OpsInsights = {
			t,
			generatedAt,
			layers: layers(empty),
			errors: {
				http5xx: req.map((v, i) =>
					empty ? 0 : Math.round(v * 0.0004 * rnd(i, 7)) + (i === spike ? 14 : 0)
				),
				ingest: t.map((_, i) => (empty ? 0 : rnd(i, 8) < 0.12 ? 1 + Math.round(rnd(i, 3) * 2) : 0))
			},
			cache: {
				memory: part(0.58),
				joined: part(0.06),
				db: part(0.28),
				negative: part(0.03),
				miss: part(0.05)
			},
			latency: {
				p50: 8,
				p95: 46,
				p99: 118,
				buckets: empty
					? []
					: [
							{ label: '< 5 ms', count: 18420 },
							{ label: '5–10 ms', count: 22110 },
							{ label: '10–25 ms', count: 9840 },
							{ label: '25–50 ms', count: 3120 },
							{ label: '50–100 ms', count: 880 },
							{ label: '100–250 ms', count: 241 },
							{ label: '≥ 250 ms', count: 38 }
						]
			},
			replicas: empty
				? []
				: [
						{
							slot: 1,
							role: 'leader',
							state: 'running',
							uptimeSeconds: 3 * 86400 + 4 * 3600,
							generation: 4
						},
						{
							slot: 2,
							role: 'follower',
							state: 'running',
							uptimeSeconds: 3 * 86400 + 4 * 3600 + 40,
							generation: 4
						}
					],
			restartPendingKeys: empty ? [] : ['CACHE_MAX_MB']
		};
		return o;
	}

	if (path === '/insights/traffic') {
		const req = empty ? pad(n) : series(t, hours, 2600, 1);
		const spike = Math.floor(n * 0.62);
		const o: TrafficInsights = {
			t,
			generatedAt,
			requests: req,
			bytes: req.map((v, i) => Math.round(v * (26000 + rnd(i, 2) * 6000))),
			status: {
				'2xx': req.map((v) => Math.round(v * 0.676)),
				'3xx': req.map((v) => Math.round(v * 0.31)),
				'4xx': req.map((v, i) => Math.round(v * 0.012 * (0.6 + rnd(i, 5)))),
				'5xx': req.map((v, i) =>
					empty ? 0 : Math.round(v * 0.0004 * rnd(i, 7)) + (i === spike ? 14 : 0)
				)
			},
			routes: empty ? [] : routeTable(total(req)),
			rateLimited: empty
				? { push: 0, dashboard: 0, other: 0 }
				: { push: 41, dashboard: 3, other: 12 },
			pageViews: empty ? pad(n) : series(t, hours, 14, 6, 0.5),
			pattern: Array.from({ length: 7 }, (_, d) =>
				Array.from({ length: 24 }, (_, h) =>
					empty
						? 0
						: Math.min(
								1,
								(diurnal(`2026-11-0${d + 2}T${String(h).padStart(2, '0')}:00:00Z`) / 1.15) *
									(0.9 + rnd(d * 24 + h, 12) * 0.2)
							)
				)
			)
		};
		return o;
	}

	if (path === '/insights/push') {
		const del = empty ? pad(n) : series(t, hours, 250, 14);
		const o: PushInsights = {
			t,
			generatedAt,
			paused: false,
			funnel: empty
				? []
				: [
						{ key: 'trigger', label: 'Auslöser (Auswertungen)', count: 18420 },
						{ key: 'relevant', label: 'Regen erwartet', count: 6310 },
						{ key: 'enqueued', label: 'In Warteschlange', count: 5990 },
						{ key: 'sent', label: 'An APNs gesendet', count: 5984 },
						{ key: 'delivered', label: 'Von APNs angenommen', count: 5871 }
					],
			skipped: empty
				? []
				: [
						{ key: 'cooldown', label: 'Sperrzeit aktiv', count: 3120 },
						{ key: 'hysteresis', label: 'Hysterese (zu nah an letzter Meldung)', count: 2210 },
						{ key: 'slot_busy', label: 'Platz belegt (Live Activity läuft)', count: 640 },
						{ key: 'disabled', label: 'Abo pausiert', count: 410 }
					],
			apnsErrors: empty
				? []
				: [
						{ key: 'Unregistered', label: 'Unregistered', count: 62 },
						{ key: 'BadDeviceToken', label: 'BadDeviceToken', count: 31 },
						{ key: 'TooManyRequests', label: 'TooManyRequests', count: 4 }
					],
			invalidated: empty
				? []
				: [
						{ key: 'push', label: 'Geräte-Token', count: 58 },
						{ key: 'la_start', label: 'Live-Activity-Start-Token', count: 21 },
						{ key: 'la_update', label: 'Live-Activity-Update-Token', count: 14 }
					],
			delivery: {
				delivered: del,
				failed: del.map((v, i) => Math.round(v * 0.019 * (0.5 + rnd(i, 3))))
			},
			lifecycle: {
				started: empty ? pad(n) : series(t, hours, 6, 21, 0.6),
				updated: empty ? pad(n) : series(t, hours, 19, 22, 0.4),
				ended: empty ? pad(n) : series(t, hours, 5, 23, 0.6)
			},
			outbox: empty
				? { pending: 0, failed: 0, oldestAgeSeconds: null }
				: { pending: 12, failed: 3, oldestAgeSeconds: 38 },
			checklist: empty
				? []
				: [
						{
							id: 'apns',
							label: 'APNs-Zugang konfiguriert',
							tone: 'ok',
							detail: 'Schlüssel vorhanden, Token gültig.'
						},
						{
							id: 'env',
							label: 'Umgebung passt zu den Installationen',
							tone: 'warn',
							detail: 'APNS_ENV=production; 80 Installationen melden sandbox und erhalten nichts.'
						},
						{
							id: 'start-token',
							label: 'Live-Activity-Start-Token vorhanden',
							tone: 'warn',
							detail:
								'74 % der Installationen mit aktivierter Live Activity haben einen Start-Token.'
						},
						{
							id: 'outbox',
							label: 'Warteschlange gesund',
							tone: 'ok',
							detail: 'Ältester Eintrag 38 s, 3 endgültig fehlgeschlagen.'
						},
						{
							id: 'leader',
							label: 'Versand-Leader vorhanden',
							tone: 'ok',
							detail: 'Replikat 1 führt seit 3 Tagen.'
						}
					]
		};
		return o;
	}

	if (path === '/insights/distribution') {
		const d: DistributionInsights = {
			generatedAt,
			minGroup: 5,
			groups: empty
				? []
				: [
						{
							id: 'locale',
							title: 'Sprache',
							items: [
								{ label: 'Deutsch', count: 812 },
								{ label: 'Englisch', count: 391 },
								{ label: 'Französisch', count: 44 },
								{ label: 'Italienisch', count: 21 },
								{ label: 'Sonstige', count: null }
							]
						},
						{
							id: 'env',
							title: 'APNs-Umgebung',
							items: [
								{ label: 'production', count: 1204 },
								{ label: 'sandbox', count: 80 }
							]
						},
						{
							id: 'la',
							title: 'Live Activity aktiviert',
							items: [
								{ label: 'Ja', count: 531 },
								{ label: 'Nein', count: 753 }
							]
						},
						{
							id: 'subs',
							title: 'Abos je Installation',
							items: [
								{ label: '1', count: 402 },
								{ label: '2', count: 214 },
								{ label: '3', count: 91 },
								{ label: '4 oder mehr', count: 22 },
								{ label: '0', count: 555 }
							]
						}
					],
			fill: empty
				? []
				: [
						{ label: 'Regionszellen belegt', ratio: 0.601, note: '48.120 von 80.000' },
						{ label: 'Cache im Arbeitsspeicher', ratio: 0.74, note: '189 von 256 MB je Replikat' },
						{ label: 'Warteschlange', ratio: 0.003, note: '12 von 4.000 Einträgen' }
					]
		};
		return d;
	}

	if (path === '/devices') {
		const now = Date.now();
		const dev: LinkedDevice = {
			ref: 'd-7f3a',
			name: 'Test-iPhone',
			env: 'production',
			channel: 'testflight',
			linkedAt: new Date(now - 9 * 86400_000).toISOString(),
			expiresAt: new Date(now + 21 * 86400_000).toISOString(),
			lastSeenAt: new Date(now - 4 * 60_000).toISOString(),
			diagnosis: [
				{
					id: 'token',
					label: 'Geräte-Token gültig',
					tone: 'ok',
					detail: 'Zuletzt erneuert vor 2 Tagen.'
				},
				{
					id: 'env',
					label: 'Umgebung passt',
					tone: 'ok',
					detail: 'Installation: production, Server: production.'
				},
				{
					id: 'la-enabled',
					label: 'Live Activity aktiviert',
					tone: 'ok',
					detail: 'Im Abo eingeschaltet.'
				},
				{
					id: 'la-token',
					label: 'Start-Token vorhanden',
					tone: 'err',
					detail:
						'Es wurde noch kein Live-Activity-Start-Token gemeldet. Die App einmal im Vordergrund öffnen.'
				},
				{
					id: 'slot',
					label: 'Platz frei',
					tone: 'warn',
					detail: 'Eine Live Activity wurde vor 41 Minuten gestartet und läuft noch.'
				}
			],
			events: [
				{
					at: new Date(now - 41 * 60_000).toISOString(),
					kind: 'Live Activity gestartet',
					tone: 'ok',
					detail: 'Regen in 12 Minuten erwartet.'
				},
				{
					at: new Date(now - 3 * HOUR).toISOString(),
					kind: 'Testpush',
					tone: 'ok',
					detail: 'Von APNs angenommen.'
				},
				{
					at: new Date(now - 26 * HOUR).toISOString(),
					kind: 'Live Activity gestartet',
					tone: 'err',
					detail: 'Übersprungen: Start-Token fehlt.'
				},
				{
					at: new Date(now - 9 * 86400_000).toISOString(),
					kind: 'Gekoppelt',
					tone: 'info',
					detail: 'Kopplung über Code bestätigt.'
				}
			]
		};
		const list: DeviceList = { maxDevices: 3, devices: empty ? [] : [dev] };
		return list;
	}
	const am = path.match(/^\/devices\/([^/]+)\/actions$/);
	if (am && method === 'POST') {
		const labels: Record<string, string> = {
			'test-push': 'Testpush an APNs übergeben.',
			'la-start': 'Live-Activity-Start angefordert.',
			'la-end': 'Live Activity wird beendet.',
			're-evaluate': 'Neuauswertung angestoßen.',
			unlink: 'Kopplung widerrufen.'
		};
		return { ok: true, message: labels[String(body.action)] ?? 'Erledigt.' };
	}
	return undefined;
}
