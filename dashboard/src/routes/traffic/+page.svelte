<script lang="ts">
	import Donut from '#lib/charts/Donut.svelte';
	import HeatStrip from '#lib/charts/HeatStrip.svelte';
	import RankBars from '#lib/charts/RankBars.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import { formatBytes, formatNumber, formatPercent, formatWeekday } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, sparkValues, sum, unpack } from '#lib/insights/series.js';
	import { pageName, routeLabel } from '#lib/insights/text.js';
	import type { TrafficInsights } from '#lib/insights/types.js';

	const res = live((r) => insights.traffic(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const rlName: Record<string, string> = {
		push: 'Push',
		dashboard: 'Dashboard',
		other: 'Sonstige'
	};
	const clsName: Record<string, string> = {
		'2xx': '2xx Erfolg',
		'3xx': '3xx nicht geändert',
		'4xx': '4xx Client',
		'5xx': '5xx Server'
	};
	const clsColor = { '2xx': 1, '3xx': 3, '4xx': 'warn', '5xx': 'err' } as const;

	/** Zeilen je Kalendertag (UTC), Spalten je Stunde; Intensitaet relativ zur staerksten Stunde. */
	function heatRows(h: NonNullable<TrafficInsights['hourly']>) {
		const max = Math.max(1, ...h.cells.map((c) => c.count));
		const days = [...new Set(h.cells.map((c) => c.date))].sort();
		return days.map((d) => {
			const byHour = new Map(h.cells.filter((c) => c.date === d).map((c) => [c.hour, c.count]));
			return {
				label: formatWeekday(`${d}T12:00:00Z`),
				cells: Array.from({ length: 24 }, (_, hour) => {
					const n = byHour.get(hour);
					return {
						v: (n ?? 0) / max,
						label:
							n === undefined
								? `${hour}:00 UTC: keine Daten`
								: `${String(hour).padStart(2, '0')}:00 UTC: ${formatNumber(n)} Anfragen`
					};
				})
			};
		});
	}
</script>

<PageHeader title="Traffic" description="Anfragen, Datenmenge, Routen und Nutzungsmuster." />

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="kpis" /><Skeletons /></div>
	{/snippet}
	{#snippet children(o)}
		{@const req = unpack(o.requests.series)}
		{@const lab = bucketLabels(req.t, o.requests.series.resolution)}
		{@const limited = sum(o.rateLimited.map((r) => r.count))}
		{@const bytes = sum(o.requests.byRoute.map((r) => r.bytes))}
		{@const hourlyRange = ctx.range === '24h' || ctx.range === '72h'}
		{@const dayFallback = hourlyRange && o.requests.series.resolution === 'day'}

		{#if o.requests.total === 0}
			<Panel>
				<EmptyState
					title="Noch keine Anfragen im Zeitraum"
					reason="Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden). Wähle einen längeren Zeitraum oder prüfe, ob der Dienst Anfragen erhält."
				/>
			</Panel>
		{:else}
			<section
				aria-label="Kennzahlen {rangeTitle}"
				class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4"
			>
				<Kpi
					label="Anfragen"
					value={formatNumber(o.requests.total)}
					series={sparkValues(o.requests.series)}
				/>
				<Kpi
					label="Datenmenge"
					value={bytes > 0 ? formatBytes(bytes) : '–'}
					hint={bytes > 0 ? 'ausgehend, alle Routen' : 'noch nicht erfasst'}
				/>
				<Kpi
					label="Nicht geändert (304)"
					value={o.requests.notModifiedShare === null
						? '–'
						: formatPercent(o.requests.notModifiedShare)}
					hint="spart Übertragung"
				/>
				<Kpi
					label="Rate-Limit-Treffer"
					value={formatNumber(limited)}
					tone={limited > 100 ? 'warn' : 'ok'}
					hint="Push, Dashboard, sonstige"
				/>
			</section>

			<Panel
				title="Anfragen"
				description={dayFallback
					? 'Je Tag (UTC): Stundenzähler noch nicht erfasst, Anzeige in Tageswerten.'
					: `Je Zeitabschnitt (UTC), ${rangeTitle}.`}
			>
				<XYChart
					label="Anfragen {rangeTitle}"
					kind="area"
					categories={lab.categories}
					ticks={lab.ticks}
					height={230}
					series={[{ key: 'r', label: 'Anfragen', values: req.v, color: 1 }]}
					format={formatNumber}
				/>
			</Panel>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
				<Panel
					class="lg:col-span-3"
					title="Statusklassen"
					description="Antworten nach HTTP-Klasse im Zeitraum."
				>
					<Donut
						label="Statusklassen"
						centerValue={formatNumber(o.requests.total)}
						centerLabel="Antworten"
						format={formatNumber}
						parts={o.requests.byStatusClass.map((c) => ({
							label: clsName[c.class] ?? c.class,
							value: c.count,
							color: clsColor[c.class as keyof typeof clsColor] ?? 5
						}))}
					/>
				</Panel>
				<Panel
					class="lg:col-span-2"
					title="Rate-Limits"
					description="Abgewiesene Anfragen nach Bereich."
				>
					{#if limited === 0}
						<EmptyState
							compact
							title="Keine Treffer"
							reason="Im Zeitraum wurde keine Anfrage durch eine Begrenzung abgewiesen."
						/>
					{:else}
						<RankBars
							label="Rate-Limit-Treffer nach Bereich"
							format={formatNumber}
							color={2}
							items={o.rateLimited.map((r) => ({
								label: rlName[r.kind] ?? r.kind,
								value: r.count
							}))}
						/>
					{/if}
				</Panel>
			</div>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
				<Panel class="lg:col-span-2" title="Routen" description="Anfragen je Routengruppe.">
					<RankBars
						label="Routen nach Anfragen"
						items={o.requests.byRoute.map((r) => ({
							label: routeLabel(r.route),
							value: r.count,
							note: formatPercent(r.count / o.requests.total)
						}))}
						format={formatNumber}
					/>
				</Panel>
				<Panel class="lg:col-span-3" title="Daten je Route" flush>
					<DataTable
						caption="Routen mit Anfragen und Datenmenge"
						rows={o.requests.byRoute}
						rowKey={(r) => r.route}
						columns={[
							{ key: 'route', label: 'Route', format: (r) => routeLabel(r.route) },
							{
								key: 'count',
								label: 'Anfragen',
								align: 'right',
								format: (r) => formatNumber(r.count)
							},
							{ key: 'bytes', label: 'Daten', align: 'right', format: (r) => formatBytes(r.bytes) },
							{
								key: 'avg',
								label: 'Ø je Anfrage',
								align: 'right',
								format: (r) => (r.count ? formatBytes(r.bytes / r.count) : '–')
							}
						]}
					/>
				</Panel>
			</div>

			<Panel
				title="Nutzungsmuster"
				description="Anfragen nach Tag und Stunde (UTC), höchstens die letzten 72 Stunden."
				info="Je dunkler eine Zelle, desto mehr Anfragen im Verhältnis zur stärksten Stunde. Hilft, Wartungsfenster in ruhigen Zeiten zu planen."
			>
				{#if o.hourly === null}
					<EmptyState
						compact
						title="Noch keine Stundenwerte"
						reason="Stundenzeilen entstehen mit dem Metriken-Paket (WP11); bis dahin gibt es nur Tageswerte."
					/>
				{:else}
					<HeatStrip
						label="Anfragen nach Tag und Stunde"
						cellHeight={24}
						axis={['00 Uhr', '23 Uhr']}
						rows={heatRows(o.hourly)}
					/>
				{/if}
			</Panel>

			<Panel
				title="Seitenaufrufe"
				description="Aufrufe der öffentlichen Textseiten, ohne Personenbezug."
			>
				<RankBars
					label="Seitenaufrufe"
					color={4}
					format={formatNumber}
					items={o.pageViews.map((p) => ({ label: pageName[p.page] ?? p.page, value: p.count }))}
				/>
			</Panel>
		{/if}
	{/snippet}
</Loadable>
