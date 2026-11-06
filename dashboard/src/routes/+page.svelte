<script lang="ts">
	import CircleCheckIcon from '@lucide/svelte/icons/circle-check';
	import { resolve } from '$app/paths';
	import XYChart from '#lib/charts/XYChart.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import { formatDateTime, formatDuration, formatNumber, formatPercent } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import FindingList from '#lib/insights/FindingList.svelte';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, deltaRatio, sparkValues, unpack } from '#lib/insights/series.js';
	import { levelTone } from '#lib/insights/text.js';
	import type { Kpi as KpiData } from '#lib/insights/types.js';

	const res = live((r) => insights.overview(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const tone = (k: KpiData) => (k.level === 'unknown' ? undefined : levelTone(k.level));
	const num = (v: number | null) => (v === null ? '–' : formatNumber(v));
	const pct = (v: number | null) => (v === null ? '–' : formatPercent(v));
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
		{@const k = o.kpis}
		{@const req = unpack(k.requests.series)}
		{@const hit = unpack(k.cacheHitRatio.series)}
		{@const lab = bucketLabels(req.t, o.resolution)}
		{@const labHit = bucketLabels(hit.t, o.resolution)}

		<Panel
			title={o.status.level === 'ok'
				? 'Alles unauffällig'
				: o.status.level === 'unknown'
					? 'Noch keine Bewertung möglich'
					: `${o.status.findingCount} ${o.status.findingCount === 1 ? 'Befund' : 'Befunde'} mit Aufmerksamkeit`}
			description="Was ist auffällig? Feste Regeln mit Schwellen aus der Konfiguration."
			info="Befunde entstehen aus festen Regeln (veraltete Ebenen, Fehlerquoten, Push-Voraussetzungen). Sie erscheinen, sobald eine Schwelle überschritten ist, und verschwinden von selbst."
		>
			{#if o.notable.length === 0}
				<EmptyState
					compact
					icon={CircleCheckIcon}
					title={o.status.level === 'unknown' ? 'Noch keine Daten' : 'Keine Befunde'}
					reason={o.status.level === 'unknown'
						? 'Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden). Ohne Daten lassen sich keine Regeln auswerten.'
						: 'Alle Regeln sind erfüllt. Neue Befunde erscheinen hier, sobald eine Schwelle überschritten wird.'}
				/>
			{:else}
				<FindingList findings={o.notable} />
			{/if}
		</Panel>

		<section
			aria-label="Kennzahlen {rangeTitle}"
			class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-3"
		>
			<Kpi
				label="Anfragen"
				value={num(k.requests.value)}
				tone={tone(k.requests)}
				delta={deltaRatio(k.requests.deltaPct)}
				goodWhen="none"
				series={sparkValues(k.requests.series)}
			/>
			<Kpi
				label="Cache-Quote"
				value={pct(k.cacheHitRatio.value)}
				tone={tone(k.cacheHitRatio)}
				delta={deltaRatio(k.cacheHitRatio.deltaPct)}
				series={sparkValues(k.cacheHitRatio.series)}
				hint="noch keine Anfragen"
			/>
			<Kpi
				label="Alter der jüngsten Aufnahme"
				value={k.ingestAgeSeconds.value === null ? '–' : formatDuration(k.ingestAgeSeconds.value)}
				tone={tone(k.ingestAgeSeconds)}
				hint="Ältester Stand der aktivierten Ebenen"
			/>
			<Kpi
				label="Push-Zustellquote"
				value={pct(k.pushDeliveryRatio.value)}
				tone={tone(k.pushDeliveryRatio)}
				delta={deltaRatio(k.pushDeliveryRatio.deltaPct)}
				series={sparkValues(k.pushDeliveryRatio.series)}
				hint={o.pushEnabled ? 'noch keine Sendungen' : 'Push ist ausgeschaltet'}
			/>
			<Kpi
				label="Aktive Live Activities"
				value={num(k.activeLiveActivities.value)}
				tone={tone(k.activeLiveActivities)}
				hint={o.pushEnabled ? 'Momentaufnahme' : 'Push ist ausgeschaltet'}
			/>
			<Kpi
				label="Push-Versand"
				value={!o.pushEnabled ? 'Aus' : o.pushPaused ? 'Pausiert' : 'Aktiv'}
				tone={!o.pushEnabled ? undefined : o.pushPaused ? 'warn' : 'ok'}
				hint="Steuerung unter Push"
			/>
		</section>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
			<Panel
				title="Anfragen"
				description="Alle öffentlichen Routen, {rangeTitle}."
				info="Summe der Anfragen je Zeitabschnitt (UTC). Die Zähler werden einmal pro Minute geschrieben."
			>
				<XYChart
					label="Anfragen {rangeTitle}"
					kind="area"
					categories={lab.categories}
					ticks={lab.ticks}
					series={[{ key: 'req', label: 'Anfragen', values: req.v, color: 1 }]}
					format={formatNumber}
				/>
			</Panel>
			<Panel
				title="Cache-Quote"
				description="Anteil der Anfragen aus dem Cache."
				info="Treffer geteilt durch alle Abfragen je Zeitabschnitt."
			>
				<XYChart
					label="Cache-Quote {rangeTitle}"
					kind="line"
					zero={false}
					yMax={1}
					categories={labHit.categories}
					ticks={labHit.ticks}
					series={[{ key: 'hit', label: 'Treffer', values: hit.v, color: 3 }]}
					format={formatPercent}
					axisFormat={formatPercent}
				/>
			</Panel>
		</div>

		<p class="text-muted-foreground text-[12px]">
			Stand <time>{formatDateTime(o.generatedAt)}</time>, Zähler laufen bis zu 60 s nach.
			<a href={resolve('/betrieb')} class="text-primary-ink font-medium hover:underline"
				>Details im Betrieb</a
			>
		</p>
	{/snippet}
</Loadable>
