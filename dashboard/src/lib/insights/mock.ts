/**
 * Erfundene Insights-Daten im Wire-Format des eingefrorenen Vertrags (docs-site/content/dashboard-api.md),
 * nur mit VITE_MOCK=1 geladen. Zustaende per URL: ?mockstate=empty | slice1 (Push-Zaehler noch null) | error | slow.
 */
import type {
	Bucket,
	Device,
	DeviceCommand,
	DeviceDetail,
	DeviceEvent,
	Diagnosis,
	DiagnosisCheck,
	DistributionInsights,
	Finding,
	Gauge,
	Kpi,
	Level,
	OpsInsights,
	OpsLayer,
	OverviewInsights,
	PushInsights,
	Range,
	Resolution,
	Series,
	TrafficInsights
} from './types';

/** `sparse`: Stundenwerte nur fuer eine Stunde (Datenmenge noch nicht erfasst); `dayonly`: Stundenzaehler fehlen, Tagesreihe. */
export type MockState =
	'normal' | 'empty' | 'slice1' | 'sparse' | 'dayonly' | 'pairopen' | 'pairending';

const HOUR = 3600_000;
function rnd(i: number, salt = 0): number {
	const x = Math.sin((i + 1) * 12.9898 + salt * 78.233) * 43758.5453;
	return x - Math.floor(x);
}

function grid(range: Range): { t: string[]; resolution: Resolution; hours: number } {
	const resolution: Resolution = range === '24h' || range === '72h' ? 'hour' : 'day';
	const count = range === '24h' ? 24 : range === '72h' ? 72 : range === '7d' ? 7 : 30;
	const hours = resolution === 'hour' ? 1 : 24;
	const end = Math.floor(Date.now() / (hours * HOUR)) * hours * HOUR;
	return {
		t: Array.from({ length: count }, (_, i) =>
			new Date(end - (count - 1 - i) * hours * HOUR).toISOString()
		),
		resolution,
		hours
	};
}

/** Tagesgang: ruhige Nacht, Spitzen morgens und am fruehen Abend (UTC). */
function diurnal(iso: string, daily = false): number {
	const d = new Date(iso);
	const wk = d.getUTCDay() === 0 || d.getUTCDay() === 6 ? 0.9 : 1;
	if (daily) return wk;
	const h = d.getUTCHours();
	return (
		wk *
		(0.42 + 0.34 * Math.exp(-Math.pow((h - 6) / 3, 2)) + 0.5 * Math.exp(-Math.pow((h - 16) / 4, 2)))
	);
}

function ser(
	t: string[],
	resolution: Resolution,
	hours: number,
	perHour: number,
	salt: number,
	noise = 0.14
): Series {
	return {
		resolution,
		points: t.map((x, i) => ({
			t: x,
			v: Math.round(
				perHour * hours * diurnal(x, resolution === 'day') * (1 - noise / 2 + rnd(i, salt) * noise)
			)
		}))
	};
}
const mapSeries = (s: Series, f: (v: number, i: number) => number): Series => ({
	resolution: s.resolution,
	points: s.points.map((p, i) => ({ t: p.t, v: p.v === null ? null : f(p.v, i) }))
});
const total = (s: Series) => s.points.reduce((a, p) => a + (p.v ?? 0), 0);
const emptySeries = (resolution: Resolution): Series => ({ resolution, points: [] });
const iso = (msAgo: number) => new Date(Date.now() - msAgo).toISOString();
const bucket = (key: string, count: number, suppressed = false): Bucket => ({
	key,
	count: suppressed ? null : count,
	suppressed
});
const gauge = (used: number, max: number): Gauge => ({
	used,
	max,
	ratio: Number((used / max).toFixed(4))
});

const kpi = (
	value: number | null,
	unit: Kpi['unit'],
	deltaPct: number | null,
	level: Level,
	series: Series | null
): Kpi => ({ value, unit, deltaPct, level, series });

function findings(empty: boolean): Finding[] {
	if (empty) return [];
	return [
		{
			code: 'layer_stale',
			level: 'warning',
			subject: 'lightning',
			value: 3120,
			threshold: 1800,
			unit: 'seconds',
			since: iso(52 * 60_000)
		},
		{
			code: 'la_start_ratio_low',
			level: 'warning',
			subject: null,
			value: 0.62,
			threshold: 0.7,
			unit: 'ratio',
			since: iso(6 * HOUR)
		}
	];
}

function layers(range: Range, empty: boolean): OpsLayer[] {
	const mk = (
		id: string,
		cadence: number,
		age: number | null,
		level: Level,
		bad: number,
		salt: number,
		lagP50: number | null
	): OpsLayer => {
		const n = Math.min(288, Math.round(86400 / cadence));
		const end = Math.floor(Date.now() / (cadence * 1000)) * cadence * 1000;
		const runs =
			age === null || empty
				? []
				: Array.from({ length: n }, (_, i) => {
						const slot = new Date(end - (n - 1 - i) * cadence * 1000).toISOString();
						let result: 'ok' | 'error' | 'missed' = 'ok';
						if (bad && rnd(i, salt) < 1 / bad)
							result = rnd(i, salt + 5) < 0.45 ? 'error' : 'missed';
						if (id === 'lightning' && i >= n - 10) result = i % 4 === 0 ? 'error' : 'missed';
						return { slot, result };
					});
		const { t, resolution } = grid(range);
		return {
			id,
			enabled: true,
			hasData: age !== null && !empty,
			latestRun: age === null || empty ? null : '20261106T0910Z',
			publishedAt: age === null || empty ? null : iso(age * 1000),
			ageSeconds: empty ? null : age,
			cadenceSeconds: cadence,
			level: empty ? 'unknown' : level,
			runs,
			lag: {
				p50Seconds: empty ? null : lagP50,
				p95Seconds: empty || lagP50 === null ? null : Math.round(lagP50 * 1.7),
				series:
					empty || lagP50 === null
						? null
						: {
								resolution,
								points: t.map((x, i) => ({
									t: x,
									v: Math.round(lagP50 * (0.85 + rnd(i, salt + 1) * 0.4))
								}))
							}
			}
		};
	};
	return [
		mk('radar', 300, 142, 'ok', 60, 1, 190),
		mk('pressure', 900, 480, 'ok', 0, 2, 410),
		mk('lightning', 600, 3120, 'warning', 14, 3, 95),
		mk('clouds', 900, null, 'unknown', 0, 4, null)
	];
}

const cmds = new Map<
	string,
	{ count: number; kind: string; dryRun: boolean | null; createdAt: string }
>();
let devices: Device[] | null = null;
/** Kopplungsfenster (Ende in ms seit Epoche; null = geschlossen). */
let pairingEnds: number | null | undefined;
function pairingNow(state: MockState): { open: boolean; endsAt: string | null } {
	if (pairingEnds === undefined)
		pairingEnds =
			state === 'pairopen'
				? Date.now() + 5 * 60_000
				: state === 'pairending'
					? Date.now() + 40_000
					: null;
	if (pairingEnds !== null && pairingEnds <= Date.now()) pairingEnds = null;
	return pairingEnds === null
		? { open: false, endsAt: null }
		: { open: true, endsAt: new Date(pairingEnds).toISOString().replace(/\.\d+Z$/, 'Z') };
}
function deviceList(empty: boolean): Device[] {
	devices ??= [
		{
			id: '0f8c2d6a-5b1e-4f3a-9c77-2e4d8a6b1c30',
			label: 'Test-iPhone',
			pairedAt: iso(9 * 86400_000),
			expiresAt: null,
			lastSeenAt: iso(4 * 60_000),
			stale: false,
			lastActionAt: iso(41 * 60_000),
			env: 'production',
			summary: { level: 'critical', code: 'no_start_token' }
		}
	];
	return empty ? [] : devices;
}

function diagnosis(): Diagnosis {
	const c = (
		order: number,
		code: string,
		level: Level,
		reason: string,
		params: DiagnosisCheck['params'] = {}
	): DiagnosisCheck => ({ order, code, level, reason, params });
	return {
		generatedAt: new Date().toISOString(),
		verdict: { code: 'start_token', level: 'critical' },
		checks: [
			c(1, 'server', 'ok', 'ok'),
			c(2, 'environment', 'ok', 'ok'),
			c(3, 'device_token', 'ok', 'ok', { ageDays: 2 }),
			c(4, 'start_token', 'critical', 'missing'),
			c(5, 'subscription', 'ok', 'ok'),
			c(6, 'slot', 'warning', 'activity_running', { ageMinutes: 41 }),
			c(7, 'lock', 'ok', 'ok'),
			c(8, 'trigger', 'ok', 'below_threshold', { thresholdClass: 5, currentMaxClass: 2 }),
			c(9, 'last_result', 'critical', 'dropped')
		]
	};
}

export function mockInsights(
	path: string,
	method: string,
	params: URLSearchParams,
	body: Record<string, unknown>,
	state: MockState
): unknown | undefined {
	const empty = state === 'empty';
	const slice1 = state === 'slice1';
	const range = (
		['24h', '72h', '7d', '30d'].includes(params.get('range') ?? '') ? params.get('range') : '24h'
	) as Range;
	const { t, resolution, hours } = grid(range);
	const generatedAt = new Date().toISOString();
	const req = empty
		? { resolution, points: t.map((x) => ({ t: x, v: 0 })) }
		: ser(t, resolution, hours, 7700, 1);
	const sparse = state === 'sparse';
	const dayOnly = state === 'dayonly' && (range === '24h' || range === '72h');

	if (path === '/insights/overview') {
		const o: OverviewInsights = {
			generatedAt,
			range,
			resolution,
			pushEnabled: !empty,
			pushState: empty ? 'off' : 'on',
			pushPaused: false,
			status: { level: empty ? 'unknown' : 'warning', findingCount: findings(empty).length },
			kpis: {
				requests: kpi(
					total(req),
					'count',
					empty ? null : 6.4,
					empty ? 'unknown' : 'ok',
					empty ? null : req
				),
				cacheHitRatio: kpi(
					empty ? null : 0.948,
					'ratio',
					empty ? null : 0.7,
					empty ? 'unknown' : 'ok',
					empty
						? null
						: {
								resolution,
								points: t.map((x, i) => ({
									t: x,
									v: Number((0.935 + rnd(i, 9) * 0.03).toFixed(3))
								}))
							}
				),
				ingestAgeSeconds: kpi(empty ? null : 187, 'seconds', null, empty ? 'unknown' : 'ok', null),
				pushDeliveryRatio: kpi(
					empty ? null : 0.981,
					'ratio',
					empty ? null : -0.3,
					empty ? 'unknown' : 'ok',
					empty
						? null
						: {
								resolution,
								points: t.map((x, i) => ({
									t: x,
									v: Number((0.972 + rnd(i, 11) * 0.02).toFixed(3))
								}))
							}
				),
				activeLiveActivities: kpi(empty ? null : 27, 'count', null, empty ? 'unknown' : 'ok', null)
			},
			notable: findings(empty),
			partial: []
		};
		return o;
	}
	if (path === '/insights/findings')
		return { generatedAt, level: empty ? 'ok' : 'warning', findings: findings(empty) };

	if (path === '/insights/ops') {
		const spike = Math.floor(t.length * 0.62);
		const hit = (salt: number) => ({
			resolution,
			points: t.map((x, i) => ({
				t: x,
				v: empty ? null : Number((0.935 + rnd(i, salt) * 0.03).toFixed(3))
			}))
		});
		const o: OpsInsights = {
			generatedAt,
			range,
			resolution,
			partial: [],
			layers: layers(range, empty),
			errors: {
				status5xx: {
					series: empty
						? emptySeries(resolution)
						: mapSeries(req, (v, i) => Math.round(v * 0.0004 * rnd(i, 7)) + (i === spike ? 14 : 0)),
					ratio1h: empty ? null : 0.0004,
					byRoute: empty
						? []
						: [
								{ route: 'radar_image', count: 11 },
								{ route: 'layer_image', count: 4 },
								{ route: 'push', count: 2 }
							]
				},
				ingestErrors: empty
					? emptySeries(resolution)
					: {
							resolution,
							points: t.map((x, i) => ({
								t: x,
								v: rnd(i, 8) < 0.12 ? 1 + Math.round(rnd(i, 3) * 2) : 0
							}))
						},
				statsDropped: 0,
				statsFlushErrors: 0
			},
			cache: {
				hitRatio: empty ? null : 0.948,
				hitRatioRadar: empty ? null : 0.962,
				hitRatioLayer: empty ? null : 0.874,
				negativeShare: empty ? null : 0.03,
				joinedShare: empty ? null : 0.06,
				dbReads: empty ? 0 : 15890,
				series: empty ? emptySeries(resolution) : hit(9),
				fill: empty
					? null
					: {
							bytes: 189_000_000,
							maxBytes: 268_435_456,
							entries: 212,
							evictions: 14,
							scope: 'maxOfReplicas'
						}
			},
			latency:
				empty || slice1
					? null
					: [
							{
								route: 'radar_image',
								buckets: [
									{ le: '10ms', count: 18420 },
									{ le: '50ms', count: 9840 },
									{ le: '200ms', count: 880 },
									{ le: '1s', count: 41 },
									{ le: 'inf', count: 3 }
								],
								p50Ms: 10,
								p95Ms: 50,
								p99Ms: 200
							},
							{
								route: 'status',
								buckets: [
									{ le: '10ms', count: 11900 },
									{ le: '50ms', count: 540 },
									{ le: '200ms', count: 38 },
									{ le: '1s', count: 2 },
									{ le: 'inf', count: 0 }
								],
								p50Ms: 10,
								p95Ms: 10,
								p99Ms: 50
							},
							{
								route: 'push',
								buckets: [
									{ le: '10ms', count: 2100 },
									{ le: '50ms', count: 3300 },
									{ le: '200ms', count: 610 },
									{ le: '1s', count: 80 },
									{ le: 'inf', count: 6 }
								],
								p50Ms: 50,
								p95Ms: 200,
								p99Ms: 1000
							}
						],
			replicas: empty
				? []
				: [
						{
							id: '9f2a41c7',
							startedAt: iso(3 * 86400_000),
							ageSeconds: 3 * 86400,
							appliedGeneration: 4,
							revision: 'abc1234',
							level: 'ok',
							isLeader: true
						},
						{
							id: '3be08d52',
							startedAt: iso(3 * 86400_000 - 40_000),
							ageSeconds: 3 * 86400 - 40,
							appliedGeneration: 4,
							revision: 'abc1234',
							level: 'ok',
							isLeader: false
						}
					],
			generation: 4,
			leader: {
				holder: empty ? null : '9f2a41c7',
				leaseSecondsLeft: empty ? null : 22,
				changes24h: 0
			},
			db: empty || slice1 ? null : { poolUsage: 0.31, errors24h: 0, migration: '010_insights' }
		};
		return o;
	}

	if (path === '/insights/traffic') {
		const routes: [string, number, number][] = [
			['radar_image', 0.55, 36000],
			['status', 0.17, 1400],
			['push', 0.12, 8500],
			['layer_image', 0.08, 21000],
			['radar_latest', 0.05, 2400],
			['landing', 0.02, 9000],
			['other', 0.01, 800]
		];
		let series = req;
		if (sparse)
			series = {
				resolution,
				points: req.points.map((p, i, a) => ({ t: p.t, v: i === a.length - 1 ? 1538 : null }))
			};
		if (dayOnly) {
			const g = grid('7d');
			series = {
				resolution: 'day',
				points: g.t.slice(-2).map((x, i) => ({ t: x, v: i ? 1538 : 7020 }))
			};
		}
		const tot = sparse || dayOnly ? total(series) : total(req);
		const cls = (f: number, i: number) => Math.round(tot * f * (1 + (i ? rnd(i, 2) * 0.1 : 0)));
		const hourly = Array.from({ length: 72 }, (_, i) => {
			const d = new Date(Math.floor(Date.now() / HOUR) * HOUR - (71 - i) * HOUR);
			return {
				date: d.toISOString().slice(0, 10),
				hour: d.getUTCHours(),
				count: Math.round(7700 * diurnal(d.toISOString()) * (0.9 + rnd(i, 12) * 0.2))
			};
		});
		const o: TrafficInsights = {
			generatedAt,
			range,
			resolution: dayOnly ? 'day' : resolution,
			partial: [],
			requests: {
				total: tot,
				series,
				notModifiedShare: empty ? null : 0.31,
				byRoute: empty
					? []
					: routes.map(([route, f, b]) => ({
							route,
							count: Math.round(tot * f),
							bytes: sparse ? 0 : Math.round(tot * f * b)
						})),
				byStatusClass: empty
					? []
					: [
							{ class: '2xx', count: cls(0.676, 0) },
							{ class: '3xx', count: cls(0.31, 1) },
							{ class: '4xx', count: cls(0.012, 2) },
							{ class: '5xx', count: 17 }
						]
			},
			rateLimited: empty
				? []
				: [
						{ kind: 'push', count: 41 },
						{ kind: 'dashboard', count: 3 },
						{ kind: 'other', count: 12 }
					],
			pageViews: empty
				? []
				: [
						{ page: 'landing_de', count: 412 },
						{ page: 'landing_en', count: 138 },
						{ page: 'privacy', count: 71 },
						{ page: 'support', count: 34 }
					],
			hourly: empty ? null : { cells: hourly }
		};
		return o;
	}

	if (path === '/insights/push') {
		const pre = (key: string, ok: boolean, detail: string | null = null) => ({ key, ok, detail });
		const base: PushInsights = {
			generatedAt,
			range,
			resolution,
			pushEnabled: !empty,
			pushState: empty ? 'off' : 'on',
			pushPaused: false,
			partial: [],
			prerequisites: empty
				? [pre('push_enabled', false)]
				: [
						pre('push_enabled', true),
						pre('apns_env_match', false, 'sandbox_install_with_production_env'),
						pre('apns_topic_set', true),
						pre('apns_key_present', true),
						pre('capability_live_activity', true),
						pre('push_not_paused', true)
					],
			funnel: empty
				? null
				: {
						installations: {
							total: 1284,
							active1d: 702,
							active7d: 1011,
							active30d: 1240,
							byEnv: [bucket('production', 1204), bucket('sandbox', 80)],
							byLocale: [bucket('de', 812), bucket('en', 391), bucket('xx', 4, true)]
						},
						tokens: {
							withDeviceToken: 1271,
							withStartToken: 394,
							startTokenAge: [
								bucket('lt1d', 120),
								bucket('lt7d', 161),
								bucket('lt30d', 89),
								bucket('older', 24)
							]
						},
						subscriptions: {
							total: 2310,
							enabled: 2204,
							liveActivity: 531,
							liveActivityWithStartToken: 394,
							inconsistent: 3
						}
					},
			triggers: null,
			skipped: null,
			lifecycle: null,
			locks: null,
			apnsErrors: null,
			delivery: null,
			outbox: null,
			tokenInvalidations: null,
			timing: null,
			registrations: null,
			rejects: null,
			caps: null
		};
		if (empty || slice1) return base;
		const del = ser(t, resolution, hours, 250, 14);
		return {
			...base,
			triggers: [
				{ trigger: 'rain_start', count: 3120 },
				{ trigger: 'raining_now', count: 1840 },
				{ trigger: 'la_rain_start', count: 612 },
				{ trigger: 'la_raining_now', count: 241 }
			],
			skipped: [
				{ trigger: 'rain_start', reason: 'lock_60min', count: 3120 },
				{ trigger: 'rain_start', reason: 'hysteresis', count: 2210 },
				{ trigger: 'la_rain_start', reason: 'no_start_token', count: 902 },
				{ trigger: 'la_rain_start', reason: 'activity_slot_busy', count: 640 },
				{ trigger: 'rain_start', reason: 'not_enabled', count: 410 }
			],
			lifecycle: {
				events: [
					{ event: 'start', outcome: 'delivered', count: 95 },
					{ event: 'start', outcome: 'rejected', count: 6 },
					{ event: 'update', outcome: 'delivered', count: 304 },
					{ event: 'update', outcome: 'retry', count: 9 },
					{ event: 'end', outcome: 'delivered', count: 88 },
					{ event: 'expire', outcome: 'delivered', count: 11 }
				],
				activeNow: 27,
				reservationsOpen: 1,
				reservationsExpired: 2
			},
			locks: { activeLocks: 143, activitySlots: gauge(27, 5000) },
			apnsErrors: [
				{ kind: 'alert', reason: 'Unregistered', env: 'production', count: 62 },
				{ kind: 'start', reason: 'BadDeviceToken', env: 'production', count: 31 },
				{ kind: 'alert', reason: 'TooManyRequests', env: 'production', count: 4 }
			],
			delivery: {
				created: total(del),
				sent: total(del),
				delivered: Math.round(total(del) * 0.981),
				rejected: Math.round(total(del) * 0.014),
				dropped: Math.round(total(del) * 0.002),
				retry: Math.round(total(del) * 0.003),
				ratio: 0.981,
				avgAttempts: 1.04
			},
			outbox: { waiting: 12, oldestAgeSeconds: 38, retrying: 3, droppedOrExpired24h: 4 },
			tokenInvalidations: [
				{ kind: 'device', cause: '410', count: 58 },
				{ kind: 'start', cause: 'bad_device_token', count: 21 },
				{ kind: 'activity', cause: 'other', count: 14 }
			],
			timing: {
				apnsSendMs: [
					{ le: '50ms', count: 4100 },
					{ le: '200ms', count: 1620 },
					{ le: '1s', count: 230 }
				],
				evalMsP95: 420,
				cellsChecked: 48120,
				cellsMax: 80000
			},
			registrations: {
				created: ser(t, resolution, hours, 4, 21, 0.6),
				deleted: ser(t, resolution, hours, 1.5, 22, 0.8),
				retained7dRatio: 0.87
			},
			rejects: [
				{ code: 'subscription_limit', count: 14 },
				{ code: 'region_limit', count: 6 },
				{ code: 'start_token_required', count: 3 }
			],
			caps: [
				{ key: 'installations', gauge: gauge(1284, 5000) },
				{ key: 'subscriptions', gauge: gauge(2310, 20000) },
				{ key: 'region_cells', gauge: gauge(48120, 80000) },
				{ key: 'activity_subscriptions', gauge: gauge(531, 5000) }
			]
		} satisfies PushInsights;
	}

	if (path === '/insights/distribution') {
		const o: DistributionInsights = {
			generatedAt,
			minGroup: 5,
			partial: [],
			subscriptionsPerInstallation: empty
				? []
				: [bucket('0', 555), bucket('1', 402), bucket('2', 214), bucket('3+', 113)],
			regionsPerInstallation: empty
				? []
				: [bucket('0', 1090), bucket('1', 150), bucket('2', 41), bucket('3', 3, true)],
			threshold: empty
				? []
				: [bucket('3', 310), bucket('5', 640), bucket('8', 220), bucket('12', 3, true)],
			lead: empty ? [] : [bucket('10', 412), bucket('20', 1380), bucket('30', 518)],
			locale: empty ? [] : [bucket('de', 812), bucket('en', 391), bucket('xx', 4, true)],
			env: empty ? [] : [bucket('production', 1204), bucket('sandbox', 80)],
			timeSensitiveShare: empty ? null : 0.18,
			liveActivityShare: empty ? null : 0.41,
			caps: empty
				? []
				: [
						{ key: 'installations', gauge: gauge(1284, 5000) },
						{ key: 'subscriptions', gauge: gauge(2310, 20000) },
						{ key: 'region_cells', gauge: gauge(48120, 80000) }
					]
		};
		return o;
	}

	if (path === '/push/pause' && method === 'PUT')
		return { paused: body.paused === true, since: body.paused ? generatedAt : null };
	if (path === '/cache/clear' && method === 'POST')
		return { generation: 5, layer: String(body.layer ?? 'all') };

	// ---- Geraete
	if (path === '/devices' && method === 'GET')
		return {
			linkEnabled: true,
			max: 3,
			devices: deviceList(empty),
			pairing: { ...pairingNow(state), defaultMinutes: 5, maxMinutes: 15 }
		};
	if (path === '/devices/pairing' && method === 'POST') {
		pairingEnds = Date.now() + Number(body.minutes) * 60_000;
		return pairingNow(state);
	}
	if (path === '/devices/pairing' && method === 'DELETE') {
		pairingEnds = null;
		return pairingNow(state);
	}
	if (path === '/devices/pair' && method === 'POST') {
		pairingEnds = null; // erste erfolgreiche Einloesung schliesst das Fenster
		const d: Device = {
			id: crypto.randomUUID(),
			label: String(body.label ?? 'Gerät'),
			pairedAt: generatedAt,
			expiresAt: null,
			lastSeenAt: generatedAt,
			stale: false,
			lastActionAt: null,
			env: 'production',
			summary: { level: 'ok', code: 'ok' }
		};
		deviceList(false);
		devices = [...(devices ?? []), d];
		return d;
	}
	const dm = path.match(
		/^\/devices\/([^/]+)(?:\/(diagnosis|events|commands|actions)(?:\/([^/]+))?)?$/
	);
	if (dm) {
		const dev = deviceList(false).find((d) => d.id === dm[1]);
		if (!dev) return undefined;
		if (method === 'DELETE' && !dm[2]) {
			devices = (devices ?? []).filter((d) => d.id !== dev.id);
			return null;
		}
		if (!dm[2]) {
			const detail: DeviceDetail = {
				device: dev,
				installation: {
					env: dev.env,
					locale: 'de',
					ageDays: 12,
					lastSeenAt: dev.lastSeenAt,
					deviceToken: { present: true, ageDays: 2 },
					startToken: { present: false, ageDays: null }
				},
				subscriptions: [
					{
						index: 0,
						kind: 'point',
						enabled: true,
						liveActivity: true,
						thresholdClass: 5,
						leadMinutes: 20,
						timeSensitive: false,
						lockUntil: iso(-19 * 60_000),
						hysteresis: false
					},
					{
						index: 1,
						kind: 'circle',
						enabled: true,
						liveActivity: false,
						thresholdClass: 8,
						leadMinutes: 10,
						timeSensitive: true,
						lockUntil: null,
						hysteresis: false
					}
				],
				activity: {
					state: 'active',
					startedAt: iso(41 * 60_000),
					endsAt: iso(-79 * 60_000),
					tokenPresent: true
				},
				reservation: { open: false, ageSeconds: null }
			};
			return detail;
		}
		if (dm[2] === 'diagnosis') return diagnosis();
		if (dm[2] === 'events') {
			const ev: DeviceEvent[] = [
				{ at: iso(3 * 60_000), kind: 'probe', outcome: 'skipped', reason: 'no_start_token' },
				{ at: iso(41 * 60_000), kind: 'la_start', outcome: 'delivered', reason: null },
				{ at: iso(3 * HOUR), kind: 'test', outcome: 'delivered', reason: null },
				{ at: iso(26 * HOUR), kind: 'la_start', outcome: 'skipped', reason: 'no_start_token' },
				{ at: iso(30 * HOUR), kind: 'alert', outcome: 'rejected', reason: 'Unregistered' }
			];
			return { events: ev };
		}
		if (dm[2] === 'actions' && method === 'POST') {
			const id = crypto.randomUUID();
			const kind = dm[3].replace('-', '_');
			cmds.set(id, {
				count: 0,
				kind,
				dryRun: dm[3] === 'reeval' ? body.dryRun !== false : null,
				createdAt: generatedAt
			});
			return { commandId: id, kind, status: 'queued', createdAt: generatedAt };
		}
		if (dm[2] === 'commands') {
			const mode =
				typeof location !== 'undefined'
					? new URLSearchParams(location.search).get('mockcmd')
					: null;
			const view = (id: string, c: NonNullable<ReturnType<typeof cmds.get>>): DeviceCommand => {
				const done = c.count >= 2;
				const result: Record<string, Record<string, unknown>> = {
					test: { outcome: 'delivered', apnsStatus: 200, reason: null },
					la_probe: {
						outcome: 'dropped',
						apnsStatus: null,
						reason: null,
						skipped: 'no_start_token'
					},
					la_end: { outcome: 'delivered', hadActivity: true, reservationCleared: false },
					reeval: {
						dryRun: c.dryRun,
						subscriptions: [
							{ index: 0, decision: 'below_threshold', sent: null },
							{ index: 1, decision: 'lock', sent: null }
						]
					},
					reset_slot: { cleared: 'none' }
				};
				const status =
					mode === 'failed' && done
						? 'failed'
						: mode === 'expired' && done
							? 'expired'
							: done
								? 'done'
								: 'running';
				return {
					commandId: id,
					kind: c.kind,
					status,
					createdAt: c.createdAt,
					startedAt: generatedAt,
					finishedAt: done ? generatedAt : null,
					dryRun: c.dryRun,
					result: status === 'done' ? (result[c.kind] ?? {}) : null,
					error: status === 'failed' ? 'environment_not_allowed' : null
				};
			};
			if (dm[3]) {
				const c = cmds.get(dm[3]);
				if (!c) return undefined;
				c.count++;
				return view(dm[3], c);
			}
			const limit = Math.min(20, Number(params.get('limit') ?? 10) || 10);
			return {
				commands: [...cmds.entries()]
					.reverse()
					.slice(0, limit)
					.map(([id, c]) => view(id, { ...c, count: Math.max(c.count, 2) }))
			};
		}
	}
	return undefined;
}
