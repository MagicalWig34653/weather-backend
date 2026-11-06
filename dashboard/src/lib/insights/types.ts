/**
 * Insights-Vertrag (Entwurf). Maßgeblich wird docs-site/content/dashboard-api.md (WP-V);
 * bis dahin beschreiben diese Typen plausible Formen. Aenderungen betreffen nur diese Datei,
 * insights/api.ts und insights/mock.ts. Keine IDs, Tokens oder Koordinaten: nur Zaehler und feste Etiketten.
 */
import type { Range } from '#lib/design/context.svelte.js';
import type { LayerStatus } from '#lib/api.js';

export type { Range };
export type Severity = 'ok' | 'info' | 'warn' | 'error';

export interface Finding {
	id: string;
	severity: Severity;
	title: string;
	detail: string;
	/** ISO-8601; seit wann der Befund besteht. */
	since: string;
	/** Interne Zielseite fuer "Ansehen". */
	href?: string;
}

/** Zeitreihe mit gemeinsamer Zeitachse: Eintrag i aller Felder gehoert zu t[i] (ISO-8601, UTC, Bucketanfang). */
export interface Timeline {
	t: string[];
}

export interface Trend {
	value: number;
	/** Wert des Vorzeitraums; null wenn nicht vorhanden. */
	previous: number | null;
	series: number[];
}

export interface OverviewInsights extends Timeline {
	generatedAt: string;
	lagSeconds: number;
	findings: Finding[];
	kpis: {
		requests: Trend;
		cacheRatio: Trend;
		pushDeliveryRatio: Trend;
		activeActivities: Trend;
		ingestAgeSeconds: { value: number; limit: number };
		installations: Trend;
	};
	layers: LayerStatus[];
}

export type RunStatus = 'ok' | 'error' | 'missed' | 'none';

export interface OpsLayer {
	id: string;
	name: string;
	status: 'ok' | 'stale' | 'missing';
	lastRunAt: string | null;
	delayP50Seconds: number | null;
	delayP95Seconds: number | null;
	/** Aeltester zuerst; ein Eintrag je erwarteter Ingest-Lauf im Zeitraum (hoechstens 96). */
	runs: RunStatus[];
}

export interface Replica {
	slot: number;
	role: 'leader' | 'follower';
	state: 'running' | 'waiting' | 'restarting';
	uptimeSeconds: number;
	generation: number;
}

export interface OpsInsights extends Timeline {
	generatedAt: string;
	layers: OpsLayer[];
	errors: { http5xx: number[]; ingest: number[] };
	cache: { memory: number[]; joined: number[]; db: number[]; negative: number[]; miss: number[] };
	latency: { p50: number; p95: number; p99: number; buckets: { label: string; count: number }[] };
	replicas: Replica[];
	restartPendingKeys: string[];
}

export interface TrafficRoute {
	route: string;
	requests: number;
	bytes: number;
	p95Ms: number;
}

export interface TrafficInsights extends Timeline {
	generatedAt: string;
	requests: number[];
	bytes: number[];
	status: { '2xx': number[]; '3xx': number[]; '4xx': number[]; '5xx': number[] };
	routes: TrafficRoute[];
	rateLimited: { push: number; dashboard: number; other: number };
	pageViews: number[];
	/** Anfragen je Wochentag (Mo=0) und Stunde (UTC), normiert auf 0..1. */
	pattern: number[][];
}

export interface CountLabel {
	key: string;
	label: string;
	count: number;
}

export interface PushInsights extends Timeline {
	generatedAt: string;
	paused: boolean;
	funnel: CountLabel[];
	skipped: CountLabel[];
	apnsErrors: CountLabel[];
	invalidated: CountLabel[];
	delivery: { delivered: number[]; failed: number[] };
	lifecycle: { started: number[]; updated: number[]; ended: number[] };
	outbox: { pending: number; failed: number; oldestAgeSeconds: number | null };
	checklist: { id: string; label: string; tone: 'ok' | 'warn' | 'err'; detail: string }[];
}

export interface DistributionGroup {
	id: string;
	title: string;
	/** count null = unterdrueckt (Gruppe kleiner als minGroup). */
	items: { label: string; count: number | null }[];
}

export interface DistributionInsights {
	generatedAt: string;
	minGroup: number;
	groups: DistributionGroup[];
	fill: { label: string; ratio: number; note: string }[];
}

export interface DiagnosisItem {
	id: string;
	label: string;
	tone: 'ok' | 'warn' | 'err';
	detail: string;
}

export interface DeviceEvent {
	at: string;
	kind: string;
	tone: 'ok' | 'warn' | 'err' | 'info';
	detail: string;
}

export type DeviceAction = 'test-push' | 'la-start' | 'la-end' | 're-evaluate' | 'unlink';

export interface LinkedDevice {
	/** Kurzer, nicht umkehrbarer Verweis (keine Installations-ID). */
	ref: string;
	name: string;
	env: 'sandbox' | 'production';
	channel: 'testflight' | 'appstore' | 'debug' | 'unknown';
	linkedAt: string;
	expiresAt: string;
	lastSeenAt: string | null;
	diagnosis: DiagnosisItem[];
	events: DeviceEvent[];
}

export interface DeviceList {
	maxDevices: number;
	devices: LinkedDevice[];
}
