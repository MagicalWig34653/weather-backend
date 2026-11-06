/**
 * Datenzugriffsschicht des Dashboards: die einzige Stelle, die Insights-Routen kennt.
 * Vertrag: docs-site/content/dashboard-api.md. Aendert er sich, wird nur diese Datei (und types.ts) angepasst.
 */
import { api } from '#lib/client.js';
import { ApiError } from '#lib/api.js';
import { errorText } from './text.js';
import type {
	Device,
	DeviceAction,
	DeviceBundle,
	DeviceCommand,
	DeviceDetail,
	DeviceEvent,
	DeviceList,
	Diagnosis,
	DistributionInsights,
	Finding,
	Level,
	OpsInsights,
	OverviewInsights,
	PushInsights,
	Range,
	TrafficInsights
} from './types.js';

const q = (range: Range) => `?range=${encodeURIComponent(range)}`;
const enc = encodeURIComponent;

/** Klartext fuer einen Fehler (Servercode bevorzugt). */
export function describeError(e: unknown): string {
	if (e instanceof ApiError) return (e.serverCode && errorText[e.serverCode]) || e.message;
	return 'Unbekannter Fehler.';
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

	devices: () => api.get<DeviceList>('/devices'),
	/** Detail, Diagnose und Ereignisse eines Geraets in einem Zug. */
	async deviceBundle(id: string): Promise<DeviceBundle> {
		const [detail, diagnosis, events] = await Promise.all([
			api.get<DeviceDetail>(`/devices/${enc(id)}`),
			api.get<Diagnosis>(`/devices/${enc(id)}/diagnosis`),
			api.get<{ events: DeviceEvent[] }>(`/devices/${enc(id)}/events?limit=20`)
		]);
		return { detail, diagnosis, events: events.events };
	},
	pairDevice: (code: string, label: string) => api.post<Device>('/devices/pair', { code, label }),
	unpairDevice: (id: string) => api.delete<void>(`/devices/${enc(id)}`),
	runAction: (id: string, action: DeviceAction, dryRun?: boolean) =>
		api.post<{ commandId: string; kind: string; status: string; createdAt: string }>(
			`/devices/${enc(id)}/actions/${enc(action)}`,
			action === 'reeval' ? { dryRun: dryRun ?? true } : {}
		),
	command: (id: string, commandId: string) =>
		api.get<DeviceCommand>(`/devices/${enc(id)}/commands/${enc(commandId)}`)
};
