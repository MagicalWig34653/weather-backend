/**
 * Datenzugriffsschicht des Dashboards: die einzige Stelle, die Insights-Routen kennt.
 * Aendert sich der Vertrag (docs-site/content/dashboard-api.md), wird nur diese Datei
 * (und types.ts) angepasst; Seiten und Komponenten bleiben unberuehrt.
 */
import { api } from '#lib/client.js';
import type {
	DeviceAction,
	DeviceList,
	DistributionInsights,
	OpsInsights,
	OverviewInsights,
	PushInsights,
	Range,
	TrafficInsights
} from './types.js';

const q = (range: Range) => `?range=${encodeURIComponent(range)}`;

export const insights = {
	overview: (range: Range) => api.get<OverviewInsights>(`/insights/overview${q(range)}`),
	ops: (range: Range) => api.get<OpsInsights>(`/insights/ops${q(range)}`),
	traffic: (range: Range) => api.get<TrafficInsights>(`/insights/traffic${q(range)}`),
	push: (range: Range) => api.get<PushInsights>(`/insights/push${q(range)}`),
	distribution: () => api.get<DistributionInsights>('/insights/distribution'),
	devices: () => api.get<DeviceList>('/devices'),
	deviceAction: (ref: string, action: DeviceAction) =>
		api.post<{ ok: boolean; message: string }>(`/devices/${encodeURIComponent(ref)}/actions`, {
			action
		}),
	linkDevice: (code: string) => api.post<{ ok: boolean }>('/devices/link', { code })
};
