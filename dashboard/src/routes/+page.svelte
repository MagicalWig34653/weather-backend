<script lang="ts">
	import CircleCheckIcon from '@lucide/svelte/icons/circle-check';
	import { resolve } from '$app/paths';
	import XYChart from '#lib/charts/XYChart.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import type { Tone } from '#lib/design/tone.js';
	import {
		formatAgo,
		formatDateTime,
		formatDuration,
		formatNumber,
		formatPercent
	} from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import FindingList from '#lib/insights/FindingList.svelte';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, change } from '#lib/insights/series.js';
	import type { LayerStatus } from '#lib/api.js';
	import type { OverviewInsights, Severity } from '#lib/insights/types.js';

	const res = live((r) => insights.overview(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const worst = (o: OverviewInsights): Severity =>
		o.findings.some((f) => f.severity === 'error')
			? 'error'
			: o.findings.some((f) => f.severity === 'warn')
				? 'warn'
				: o.findings.some((f) => f.severity === 'info')
					? 'info'
					: 'ok';
	const actionable = (o: OverviewInsights) => o.findings.filter((f) => f.severity !== 'ok');

	const layerTone: Record<string, Tone> = { ok: 'ok', stale: 'warn', missing: 'err' };
	const layerLabel: Record<string, string> = { ok: 'Aktuell', stale: 'Veraltet', missing: 'Fehlt' };
</script>

<PageHeader
	title="Übersicht"
	description="Gesundheit des Radar-Dienstes, Traffic und Push auf einen Blick."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="list" /><Skeletons kind="kpis" /></div>
	{/snippet}
	{#snippet children(o)}
		{@const sev = worst(o)}
		{@const open = actionable(o)}
		{@const k = o.kpis}
		{@const lab = bucketLabels(o.t, ctx.range)}

		<Panel
			title={sev === 'ok'
				? 'Alles unauffällig'
				: `${open.length} ${open.length === 1 ? 'Befund' : 'Befunde'} mit Aufmerksamkeit`}
			description="Was ist auffällig? Regeln mit Schwellen aus der Konfiguration."
			info="Befunde entstehen aus festen Regeln (veraltete Ebenen, Fehlerquoten, Push-Voraussetzungen). Sie erscheinen, sobald eine Schwelle überschritten ist, und verschwinden von selbst."
		>
			{#if o.findings.length === 0}
				<EmptyState
					compact
					icon={CircleCheckIcon}
					title="Keine Befunde"
					reason="Alle Regeln sind erfüllt. Neue Befunde erscheinen hier, sobald eine Schwelle überschritten wird."
				/>
			{:else}
				<FindingList findings={o.findings} />
			{/if}
		</Panel>

		<section
			aria-label="Kennzahlen {rangeTitle}"
			class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-3"
		>
			<Kpi
				label="Anfragen"
				value={formatNumber(k.requests.value)}
				delta={change(k.requests.value, k.requests.previous)}
				goodWhen="none"
				series={k.requests.series}
			/>
			<Kpi
				label="Cache-Quote"
				value={formatPercent(k.cacheRatio.value)}
				tone={k.cacheRatio.value >= 0.9 ? 'ok' : 'warn'}
				delta={change(k.cacheRatio.value, k.cacheRatio.previous)}
				series={k.cacheRatio.series}
			/>
			<Kpi
				label="Alter der jüngsten Aufnahme"
				value={formatDuration(k.ingestAgeSeconds.value)}
				tone={k.ingestAgeSeconds.value > k.ingestAgeSeconds.limit ? 'warn' : 'ok'}
				hint="Schwelle {formatDuration(k.ingestAgeSeconds.limit)}"
			/>
			<Kpi
				label="Push-Zustellquote"
				value={formatPercent(k.pushDeliveryRatio.value)}
				tone={k.pushDeliveryRatio.value >= 0.95 ? 'ok' : 'warn'}
				delta={change(k.pushDeliveryRatio.value, k.pushDeliveryRatio.previous)}
				series={k.pushDeliveryRatio.series}
			/>
			<Kpi
				label="Aktive Live Activities"
				value={formatNumber(k.activeActivities.value)}
				delta={change(k.activeActivities.value, k.activeActivities.previous)}
				goodWhen="none"
				series={k.activeActivities.series}
				deltaLabel="ggü. Vortag"
			/>
			<Kpi
				label="Installationen"
				value={formatNumber(k.installations.value)}
				delta={change(k.installations.value, k.installations.previous)}
				goodWhen="none"
				series={k.installations.series}
			/>
		</section>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
			<Panel
				class="lg:col-span-3"
				title="Anfragen"
				description="Alle öffentlichen Routen, {rangeTitle}."
				info="Summe der Anfragen je Zeitabschnitt. Die Zähler werden einmal pro Minute geschrieben."
			>
				<XYChart
					label="Anfragen {rangeTitle}"
					kind="area"
					categories={lab.categories}
					ticks={lab.ticks}
					series={[{ key: 'req', label: 'Anfragen', values: k.requests.series, color: 1 }]}
					format={formatNumber}
				/>
			</Panel>
			<Panel
				class="lg:col-span-2"
				title="Ebenen"
				description="Jüngste gespeicherte Aufnahme je Ebene."
				flush
			>
				<DataTable
					caption="Ebenenstatus"
					rows={o.layers}
					rowKey={(l) => l.id}
					columns={[
						{ key: 'name', label: 'Ebene' },
						{ key: 'status', label: 'Status', cell: statusCell },
						{
							key: 'updated_at',
							label: 'Aufnahme',
							align: 'right',
							format: (l) => (l.updated_at ? formatAgo(l.updated_at, ctx.now) : '–')
						}
					]}
				/>
				<p class="text-muted-foreground px-5 py-3 text-[12px]">
					Stand <time>{formatDateTime(o.generatedAt)}</time>, Zähler laufen bis zu {o.lagSeconds} s nach.
					<a href={resolve('/betrieb')} class="text-primary-ink font-medium hover:underline"
						>Details im Betrieb</a
					>
				</p>
			</Panel>
		</div>
	{/snippet}
</Loadable>

{#snippet statusCell(l: LayerStatus)}
	<StatusBadge tone={layerTone[l.status]} label={layerLabel[l.status]} />
{/snippet}
