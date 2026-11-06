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
	leader: { holder: string | null; leaseSecondsLeft: number | null; changes24h: number };
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
export interface DeviceList {
	linkEnabled: boolean;
	max: number;
	devices: Device[];
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
