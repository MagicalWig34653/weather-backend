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
	import {
		formatBytes,
		formatCompact,
		formatMs,
		formatNumber,
		formatPercent
	} from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, sum } from '#lib/insights/series.js';

	const res = live((r) => insights.traffic(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');
	const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
</script>

<PageHeader title="Traffic" description="Anfragen, Datenmenge, Routen und Nutzungsmuster." />

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="kpis" /><Skeletons /></div>
	{/snippet}
	{#snippet children(o)}
		{@const lab = bucketLabels(o.t, ctx.range)}
		{@const total = sum(o.requests)}
		{@const nm = sum(o.status['3xx'])}
		{@const limited = o.rateLimited.push + o.rateLimited.dashboard + o.rateLimited.other}

		{#if total === 0}
			<Panel
				><EmptyState
					title="Noch keine Anfragen im Zeitraum"
					reason="Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden). Wähle einen längeren Zeitraum oder prüfe, ob der Dienst Anfragen erhält."
				/></Panel
			>
		{:else}
			<section
				aria-label="Kennzahlen {rangeTitle}"
				class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4"
			>
				<Kpi label="Anfragen" value={formatNumber(total)} series={o.requests} />
				<Kpi label="Datenmenge" value={formatBytes(sum(o.bytes))} series={o.bytes} />
				<Kpi
					label="Nicht geändert (304)"
					value={formatPercent(nm / total)}
					hint="spart Übertragung"
				/>
				<Kpi
					label="Rate-Limit-Treffer"
					value={formatNumber(limited)}
					tone={limited > 100 ? 'warn' : 'ok'}
					hint="Push, Dashboard, sonstige"
				/>
			</section>

			<Panel title="Anfragen und Datenmenge" description="Je Zeitabschnitt, {rangeTitle}.">
				<div class="grid grid-cols-1 gap-8 lg:grid-cols-2">
					<div>
						<p class="text-muted-foreground mb-1 text-[12px] font-medium">Anfragen</p>
						<XYChart
							label="Anfragen {rangeTitle}"
							kind="area"
							categories={lab.categories}
							ticks={lab.ticks}
							height={200}
							series={[{ key: 'r', label: 'Anfragen', values: o.requests, color: 1 }]}
							format={formatNumber}
						/>
					</div>
					<div>
						<p class="text-muted-foreground mb-1 text-[12px] font-medium">Datenmenge</p>
						<XYChart
							label="Datenmenge {rangeTitle}"
							kind="bar"
							categories={lab.categories}
							ticks={lab.ticks}
							height={200}
							series={[{ key: 'b', label: 'Ausgehend', values: o.bytes, color: 3 }]}
							format={formatBytes}
							bytes
							axisFormat={formatBytes}
						/>
					</div>
				</div>
			</Panel>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
				<Panel
					class="lg:col-span-3"
					title="Statusklassen"
					description="Antworten nach HTTP-Klasse."
				>
					<XYChart
						label="Statusklassen {rangeTitle}"
						kind="bar"
						stacked
						categories={lab.categories}
						ticks={lab.ticks}
						height={210}
						series={[
							{ key: '2', label: '2xx Erfolg', values: o.status['2xx'], color: 1 },
							{ key: '3', label: '3xx nicht geändert', values: o.status['3xx'], color: 3 },
							{ key: '4', label: '4xx Client', values: o.status['4xx'], color: 'warn' },
							{ key: '5', label: '5xx Server', values: o.status['5xx'], color: 'err' }
						]}
						format={formatNumber}
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
						<Donut
							label="Rate-Limit-Treffer nach Bereich"
							centerValue={formatNumber(limited)}
							centerLabel="gesamt"
							format={formatNumber}
							parts={[
								{ label: 'Push', value: o.rateLimited.push, color: 1 },
								{ label: 'Dashboard', value: o.rateLimited.dashboard, color: 3 },
								{ label: 'Sonstige', value: o.rateLimited.other, color: 5 }
							]}
						/>
					{/if}
				</Panel>
			</div>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
				<Panel
					class="lg:col-span-2"
					title="Routen"
					description="Anfragen je Routenvorlage (ohne Parameterwerte)."
				>
					<RankBars
						label="Routen nach Anfragen"
						items={o.routes.map((r) => ({
							label: r.route,
							value: r.requests,
							note: formatPercent(r.requests / total),
							mono: true
						}))}
						format={formatNumber}
					/>
				</Panel>
				<Panel class="lg:col-span-3" title="Details je Route" flush>
					<DataTable
						caption="Routen mit Datenmenge und Antwortzeit"
						rows={o.routes}
						rowKey={(r) => r.route}
						columns={[
							{ key: 'route', label: 'Route', class: 'font-mono text-xs' },
							{
								key: 'requests',
								label: 'Anfragen',
								align: 'right',
								format: (r) => formatNumber(r.requests)
							},
							{ key: 'bytes', label: 'Daten', align: 'right', format: (r) => formatBytes(r.bytes) },
							{ key: 'p95', label: 'p95', align: 'right', format: (r) => formatMs(r.p95Ms) }
						]}
					/>
				</Panel>
			</div>

			<Panel
				title="Nutzungsmuster"
				description="Anfragen nach Wochentag und Stunde (UTC)."
				info="Je dunkler eine Zelle, desto mehr Anfragen im Verhältnis zur stärksten Stunde. Hilft, Wartungsfenster in ruhigen Zeiten zu planen."
			>
				<HeatStrip
					label="Anfragen nach Wochentag und Stunde"
					cellHeight={22}
					axis={['00 Uhr', '23 Uhr']}
					rows={o.pattern.map((row, d) => ({
						label: days[d],
						cells: row.map((v, h) => ({
							v,
							label: `${days[d]} ${String(h).padStart(2, '0')}:00 UTC: ${formatPercent(v)} der Spitze`
						}))
					}))}
				/>
			</Panel>

			<Panel
				title="Seitenaufrufe"
				description="Aufrufe der öffentlichen Seiten, ohne Personenbezug."
			>
				<XYChart
					label="Seitenaufrufe {rangeTitle}"
					kind="line"
					categories={lab.categories}
					ticks={lab.ticks}
					height={160}
					series={[{ key: 'p', label: 'Seitenaufrufe', values: o.pageViews, color: 4 }]}
					format={formatCompact}
				/>
			</Panel>
		{/if}
	{/snippet}
</Loadable>
