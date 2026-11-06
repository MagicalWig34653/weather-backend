/**
 * Insights-Vertrag: Formen aus docs-site/content/dashboard-api.md (eingefroren 6.11.2026, WP-V),
 * Beispiele in docs/fixtures/dashboard/. Aufzaehlungen sind offen: Clients tolerieren unbekannte Werte
 * (Anzeige "unbekannt"). Unbekannt/nicht erhoben ist immer null, nie 0.
 */
import type { Range } from '#lib/design/context.svelte.js';
export type { Range };

export type Level = 'ok' | 'warning' | 'critical' | 'unknown';
export type Resolution = 'hour' | 'day';

export interface Series {
	resolution: Resolution;
	points: { t: string; v: number | null }[];
}
export interface Bucket {
	key: string;
	count: number | null;
	suppressed: boolean;
}
export interface Gauge {
	used: number;
	max: number;
	ratio: number;
}

export interface Kpi {
	value: number | null;
	unit: 'count' | 'ratio' | 'seconds';
	deltaPct: number | null;
	level: Level;
	series: Series | null;
}

export interface Finding {
	code: string;
	level: 'warning' | 'critical';
	subject: string | null;
	value: number;
	threshold: number;
	unit: 'ratio' | 'seconds' | 'count' | 'percent';
	since: string | null;
}

export interface OverviewInsights {
	generatedAt: string;
	range: Range;
	resolution: Resolution;
	pushEnabled: boolean;
	/** 'unknown': kein Radar-Replikat hat sich kürzlich gemeldet (nicht dasselbe wie aus). Fehlt bei älteren Servern. */
	pushState?: 'on' | 'off' | 'unknown';
	pushPaused: boolean;
	status: { level: Level; findingCount: number };
	kpis: {
		requests: Kpi;
		cacheHitRatio: Kpi;
		ingestAgeSeconds: Kpi;
		pushDeliveryRatio: Kpi;
		activeLiveActivities: Kpi;
	};
	notable: Finding[];
	partial: string[];
}

export interface OpsLayer {
	id: string;
	enabled: boolean;
	hasData: boolean;
	latestRun: string | null;
	publishedAt: string | null;
	ageSeconds: number | null;
	cadenceSeconds: number;
	level: Level;
	runs: { slot: string; result: 'ok' | 'error' | 'missed' }[];
	lag: { p50Seconds: number | null; p95Seconds: number | null; series: Series | null };
}

export interface OpsInsights {
	generatedAt: string;
	range: Range;
	resolution: Resolution;
	partial: string[];
	layers: OpsLayer[];
	errors: {
		status5xx: {
			series: Series;
			ratio1h: number | null;
			byRoute: { route: string; count: number }[];
		};
		ingestErrors: Series;
		statsDropped: number;
		/** Fehlgeschlagene Statistik-Schreibvorgaenge (Tag oder Stunde) der letzten 24 Stunden. */
		statsFlushErrors?: number;
	};
	cache: {
		hitRatio: number | null;
		hitRatioRadar: number | null;
		hitRatioLayer: number | null;
		negativeShare: number | null;
		joinedShare: number | null;
		dbReads: number;
		series: Series;
		fill: {
			bytes: number;
			maxBytes: number;
			entries: number;
			evictions: number;
			scope: string;
		} | null;
	};
	latency:
		| {
				route: string;
				buckets: { le: string; count: number }[];
				p50Ms: number | null;
				p95Ms: number | null;
				p99Ms: number | null;
		  }[]
		| null;
	replicas: {
		id: string;
		startedAt: string;
		ageSeconds: number;
		appliedGeneration: number;
		revision: string | null;
		level: Level;
		isLeader: boolean;
	}[];
	generation: number;
	leader: {
		holder: string | null;
		leaseSecondsLeft: number | null;
		changes24h: number | null;
	} | null;
	db: { poolUsage: number | null; errors24h: number | null; migration: string | null } | null;
}

export interface TrafficInsights {
	generatedAt: string;
	range: Range;
	resolution: Resolution;
	partial: string[];
	requests: {
		total: number;
		series: Series;
		notModifiedShare: number | null;
		byRoute: { route: string; count: number; bytes: number }[];
		byStatusClass: { class: string; count: number }[];
	};
	rateLimited: { kind: string; count: number }[];
	pageViews: { page: string; count: number }[];
	hourly: { cells: { date: string; hour: number; count: number }[] } | null;
}

export type PushTrigger = string;
export interface PushInsights {
	generatedAt: string;
	range: Range;
	resolution: Resolution;
	pushEnabled: boolean;
	/** 'unknown': kein Radar-Replikat hat sich kürzlich gemeldet (nicht dasselbe wie aus). Fehlt bei älteren Servern. */
	pushState?: 'on' | 'off' | 'unknown';
	pushPaused: boolean;
	partial: string[];
	prerequisites: { key: string; ok: boolean; detail: string | null }[];
	funnel: {
		installations: {
			total: number;
			active1d: number;
			active7d: number;
			active30d: number;
			byEnv: Bucket[];
			byLocale: Bucket[];
		};
		tokens: { withDeviceToken: number; withStartToken: number; startTokenAge: Bucket[] };
		subscriptions: {
			total: number;
			enabled: number;
			liveActivity: number;
			liveActivityWithStartToken: number;
			inconsistent: number;
		};
	} | null;
	triggers: { trigger: PushTrigger; count: number }[] | null;
	skipped: { trigger: PushTrigger; reason: string; count: number }[] | null;
	lifecycle: {
		events: { event: string; outcome: string; count: number }[];
		activeNow: number;
		reservationsOpen: number;
		reservationsExpired: number;
	} | null;
	locks: { activeLocks: number; activitySlots: Gauge } | null;
	apnsErrors: { kind: string; reason: string; env: string; count: number }[] | null;
	delivery: {
		created: number;
		sent: number;
		delivered: number;
		rejected: number;
		dropped: number;
		retry: number;
		ratio: number | null;
		avgAttempts: number | null;
	} | null;
	outbox: {
		waiting: number;
		oldestAgeSeconds: number | null;
		retrying: number;
		droppedOrExpired24h: number;
	} | null;
	tokenInvalidations: { kind: string; cause: string; count: number }[] | null;
	timing: {
		apnsSendMs: { le: string; count: number }[];
		evalMsP95: number | null;
		cellsChecked: number | null;
		cellsMax: number;
	} | null;
	registrations: { created: Series; deleted: Series; retained7dRatio: number | null } | null;
	rejects: { code: string; count: number }[] | null;
	caps: { key: string; gauge: Gauge }[] | null;
}

export interface DistributionInsights {
	generatedAt: string;
	minGroup: number;
	partial: string[];
	subscriptionsPerInstallation: Bucket[];
	regionsPerInstallation: Bucket[];
	threshold: Bucket[];
	lead: Bucket[];
	locale: Bucket[];
	env: Bucket[];
	timeSensitiveShare: number | null;
	liveActivityShare: number | null;
	caps: { key: string; gauge: Gauge }[];
}

// ------------------------------------------------------------------ Geraete

export interface Device {
	id: string;
	label: string;
	pairedAt: string;
	expiresAt: string | null;
	lastSeenAt: string | null;
	stale: boolean;
	lastActionAt: string | null;
	env: 'sandbox' | 'production';
	summary: { level: Level; code: string };
}
/** Kopplungsfenster: nur solange es offen ist, zeigt die App einen Koppelcode an. */
export interface PairingState {
	open: boolean;
	endsAt: string | null;
}
export interface PairingWindow extends PairingState {
	defaultMinutes: number;
	maxMinutes: number;
}
export interface DeviceList {
	linkEnabled: boolean;
	max: number;
	devices: Device[];
	/** Fehlt bei aelteren Servern; dann entfaellt das Panel. */
	pairing?: PairingWindow;
}
export interface DeviceDetail {
	device: Device;
	installation: {
		env: string;
		locale: string;
		ageDays: number;
		lastSeenAt: string | null;
		deviceToken: { present: boolean; ageDays: number | null };
		startToken: { present: boolean; ageDays: number | null };
	};
	subscriptions: {
		index: number;
		kind: string;
		enabled: boolean;
		liveActivity: boolean;
		thresholdClass: number;
		leadMinutes: number;
		timeSensitive: boolean;
		lockUntil: string | null;
		hysteresis: boolean;
	}[];
	activity: {
		state: string;
		startedAt: string | null;
		endsAt: string | null;
		tokenPresent: boolean;
	};
	reservation: { open: boolean; ageSeconds: number | null };
}
export interface DiagnosisCheck {
	order: number;
	code: string;
	level: Level;
	reason: string;
	params: Record<string, string | number | boolean | null>;
}
export interface Diagnosis {
	generatedAt: string;
	verdict: { code: string; level: Level } | null;
	checks: DiagnosisCheck[];
}
export interface DeviceEvent {
	at: string;
	kind: string;
	outcome: string;
	reason: string | null;
}
export type DeviceAction = 'test' | 'la-probe' | 'la-end' | 'reeval' | 'reset-slot';
export interface DeviceCommand {
	commandId: string;
	kind: string;
	status: 'queued' | 'running' | 'done' | 'failed' | 'expired';
	createdAt: string;
	startedAt: string | null;
	finishedAt: string | null;
	dryRun: boolean | null;
	result: Record<string, unknown> | null;
	error: string | null;
}
/** Alles, was die Geraeteseite je Geraet braucht (vier Abrufe gebuendelt). */
export interface DeviceBundle {
	detail: DeviceDetail;
	diagnosis: Diagnosis;
	events: DeviceEvent[];
	/** Letzte Auftraege, neueste zuerst (leer, wenn der Abruf scheiterte). */
	commands: DeviceCommand[];
}

// ---------------------------------------------------------------- Erweiterung 6.11.2026: Abos, Cache

/** Gemeinsame additive Felder der Insights-Antworten (stale-while-error). */
export interface StaleInfo {
	stale?: boolean;
	staleSeconds?: number;
}

export type RadarStatus = 'ok' | 'no_slot' | 'stale_run' | (string & {});
export type CellState = 'wet' | 'dry' | 'unknown' | (string & {});

export interface DeviceSubscription {
	index: number;
	kind: 'point' | 'circle' | (string & {});
	enabled: boolean;
	liveActivity: boolean;
	timeSensitive: boolean;
	thresholdClass: number;
	leadMinutes: number;
	radiusCells: number | null;
	minSharePercent: number | null;
	state: 'dry' | 'pending' | 'notified' | (string & {});
	hysteresis: boolean;
	lastSentAt: string | null;
	lockUntil: string | null;
	cell: CellState;
	leadCell: CellState;
	activity: 'none' | 'reserved' | 'active' | (string & {});
}
export interface DeviceSubscriptions extends StaleInfo {
	generatedAt: string;
	radar: { status: RadarStatus; runAgeSeconds: number | null };
	subscriptions: DeviceSubscription[];
}

export type CacheLayerState = 'current' | 'stale' | 'failed' | 'empty' | 'disabled' | (string & {});
export interface CacheLayer {
	id: string;
	kind: 'radar' | 'forecast' | 'observation' | (string & {});
	enabled: boolean;
	state: CacheLayerState;
	runs: number;
	slots: number;
	bytes: number | null;
	oldestNominal: string | null;
	newestNominal: string | null;
	spanSeconds: number | null;
	latestPublishedAt: string | null;
	ageSeconds: number | null;
	cadenceSeconds: number;
	lastAttemptAt: string | null;
	lastAttemptResult: 'ok' | 'error' | 'missed' | 'running' | null;
	errors24h: number | null;
}
export interface CacheInventory extends StaleInfo {
	generatedAt: string;
	partial: string[];
	layers: CacheLayer[];
	process: { scope: string; bytes: number; maxBytes: number; entries: number } | null;
	replicas: {
		id: string;
		cacheBytes: number | null;
		cacheEntries: number | null;
		cacheMaxBytes: number | null;
	}[];
}
export interface CacheSlot {
	slot: string;
	run: string;
	index: number;
	bytes: number;
	contentType: string;
	published: boolean;
	publishedAt: string | null;
}
export interface CacheSlotPage {
	layer: string;
	slots: CacheSlot[];
	next: string | null;
}
export interface RefreshJob {
	id: string;
	layer: string;
	status: 'queued' | 'running' | 'ok' | 'failed' | 'expired';
	createdAt: string;
	startedAt: string | null;
	finishedAt: string | null;
	result: { stored: number; failed: number; published: boolean } | null;
	error: string | null;
}
