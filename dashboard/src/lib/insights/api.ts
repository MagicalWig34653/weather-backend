/**
 * Datenzugriffsschicht des Dashboards: die einzige Stelle, die Insights-Routen kennt.
 * Vertrag: docs-site/content/dashboard-api.md. Aendert er sich, wird nur diese Datei (und types.ts) angepasst.
 */
import { api } from '#lib/client.js';
import { ApiError } from '#lib/api.js';
import { pollCommand, pollRefresh, type PollOutcome } from './poll.js';
import { mockPreviewUrl } from './mock-preview.js';
import { formatDuration } from '#lib/format.js';
import { errorText, pairingErrorText } from './text.js';
import type {
	CacheInventory,
	CacheSlotPage,
	Device,
	DeviceAction,
	DeviceBundle,
	DeviceCommand,
	DeviceDetail,
	DeviceEvent,
	DeviceList,
	DeviceSubscriptions,
	Diagnosis,
	DistributionInsights,
	Finding,
	Level,
	OpsInsights,
	OverviewInsights,
	PairingState,
	PushInsights,
	Range,
	RefreshJob,
	TrafficInsights
} from './types.js';

const q = (range: Range) => `?range=${encodeURIComponent(range)}`;
const enc = encodeURIComponent;

/** Klartext fuer einen Fehler (Servercode bevorzugt); bei 429 mit Wartezeit aus Retry-After. */
export function describeError(e: unknown): string {
	if (!(e instanceof ApiError)) return errorText.unknown;
	const base = (e.serverCode && errorText[e.serverCode]) || e.message;
	return e.code === 'rate_limited' && e.retryAfter
		? `${base} Erneut möglich in ${formatDuration(e.retryAfter)}.`
		: base;
}

/** Klartext fuer Fehler beim Oeffnen/Schliessen des Kopplungsfensters. */
export function describePairingError(e: unknown): string {
	if (e instanceof ApiError) {
		const base = e.serverCode ? pairingErrorText[e.serverCode] : undefined;
		if (base)
			return e.code === 'rate_limited' && e.retryAfter
				? `${base} Erneut möglich in ${formatDuration(e.retryAfter)}.`
				: base;
	}
	return describeError(e);
}

export const insights = {
	overview: (range: Range) => api.get<OverviewInsights>(`/insights/overview${q(range)}`),
	findings: () =>
		api.get<{ generatedAt: string; level: Level; findings: Finding[] }>('/insights/findings'),
	ops: (range: Range) => api.get<OpsInsights>(`/insights/ops${q(range)}`),
	traffic: (range: Range) => api.get<TrafficInsights>(`/insights/traffic${q(range)}`),
	push: (range: Range) => api.get<PushInsights>(`/insights/push${q(range)}`),
	distribution: () => api.get<DistributionInsights>('/insights/distribution'),

	setPaused: (paused: boolean) =>
		api.put<{ paused: boolean; since: string | null }>('/push/pause', { paused }),
	clearCache: (layer: string) =>
		api.post<{ generation: number; layer: string }>('/cache/clear', { layer }),

	cache: () => api.get<CacheInventory>('/cache'),
	/** Seiten absteigend nach Slot-Zeit; `before` = `next` der Vorseite. */
	cacheSlots: (layer: string, before?: string, limit = 200) =>
		api.get<CacheSlotPage>(
			`/cache/${enc(layer)}/slots?limit=${limit}${before ? `&before=${enc(before)}` : ''}`
		),
	/** URL fuer <img src> (CSP img-src 'self'); im Mock ein erzeugtes Platzhalterbild. */
	cachePreviewUrl: (layer: string, slot: string, run?: string): string =>
		__MOCK__
			? mockPreviewUrl(layer, slot)
			: `/dash/api/cache/${enc(layer)}/preview?slot=${enc(slot)}${run ? `&run=${enc(run)}` : ''}`,
	/** Ausserplanmaessiger Ingest-Lauf: `all`, `radar` oder eine Ebenen-ID. */
	refreshCache: (layer: string) =>
		api.post<{ jobs: { id: string; layer: string; status: string; createdAt: string }[] }>(
			'/cache/refresh',
			{ layer }
		),
	refreshJob: (id: string) => api.get<RefreshJob>(`/cache/refresh/${enc(id)}`),
	refreshJobs: (limit = 10) => api.get<{ jobs: RefreshJob[] }>(`/cache/refresh?limit=${limit}`),
	pollRefresh: (id: string, onUpdate?: (j: RefreshJob) => void): Promise<PollOutcome<RefreshJob>> =>
		pollRefresh(() => insights.refreshJob(id), {
			onUpdate,
			fatal: (e) => e instanceof ApiError && (e.code === 'unauthorized' || e.code === 'not_found')
		}),

	devices: () => api.get<DeviceList>('/devices'),
	deviceSubscriptions: (id: string) =>
		api.get<DeviceSubscriptions>(`/devices/${enc(id)}/subscriptions`),
	/** Detail, Diagnose und Ereignisse eines Geraets in einem Zug. */
	async deviceBundle(id: string): Promise<DeviceBundle> {
		const [detail, diagnosis, events, commands] = await Promise.all([
			api.get<DeviceDetail>(`/devices/${enc(id)}`),
			api.get<Diagnosis>(`/devices/${enc(id)}/diagnosis`),
			api.get<{ events: DeviceEvent[] }>(`/devices/${enc(id)}/events?limit=20`),
			// Die Auftragsliste ist Beiwerk: ihr Ausfall darf die Geraeteansicht nicht verhindern.
			api.get<{ commands: DeviceCommand[] }>(`/devices/${enc(id)}/commands?limit=5`).catch(() => ({
				commands: [] as DeviceCommand[]
			}))
		]);
		return { detail, diagnosis, events: events.events, commands: commands.commands };
	},
	openPairing: (minutes: number) => api.post<PairingState>('/devices/pairing', { minutes }),
	closePairing: () => api.delete<PairingState>('/devices/pairing'),
	pairDevice: (code: string, label: string) => api.post<Device>('/devices/pair', { code, label }),
	unpairDevice: (id: string) => api.delete<void>(`/devices/${enc(id)}`),
	runAction: (id: string, action: DeviceAction, dryRun?: boolean) =>
		api.post<{ commandId: string; kind: string; status: string; createdAt: string }>(
			`/devices/${enc(id)}/actions/${enc(action)}`,
			action === 'reeval' ? { dryRun: dryRun ?? true } : {}
		),
	command: (id: string, commandId: string) =>
		api.get<DeviceCommand>(`/devices/${enc(id)}/commands/${enc(commandId)}`),
	/** Letzte Auftraege eines Geraets, neueste zuerst (`limit` 1 bis 20). */
	commands: (id: string, limit = 5) =>
		api.get<{ commands: DeviceCommand[] }>(`/devices/${enc(id)}/commands?limit=${limit}`),
	/** Wartet auf das Ergebnis eines Auftrags (Abfrage alle 1,5 s, hoechstens 2 Minuten). */
	pollCommand: (
		id: string,
		commandId: string,
		onUpdate?: (c: DeviceCommand) => void
	): Promise<PollOutcome> =>
		pollCommand(() => insights.command(id, commandId), {
			onUpdate,
			fatal: (e) => e instanceof ApiError && (e.code === 'unauthorized' || e.code === 'not_found')
		})
};
