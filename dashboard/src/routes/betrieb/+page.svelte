<script lang="ts">
	import { resolve } from '$app/paths';
	import RotateCwIcon from '@lucide/svelte/icons/rotate-cw';
	import ServerOffIcon from '@lucide/svelte/icons/server-off';
	import HeatStrip, { type HeatRow } from '#lib/charts/HeatStrip.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import type { Tone } from '#lib/design/tone.js';
	import { formatAgo, formatDuration, formatNumber, formatPercent } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, sum } from '#lib/insights/series.js';
	import type { OpsInsights, OpsLayer, Replica } from '#lib/insights/types.js';

	const res = live((r) => insights.ops(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const runTone = { ok: 'ok', error: 'err', missed: 'warn', none: 'none' } as const;
	const runName = {
		ok: 'erfolgreich',
		error: 'Fehler',
		missed: 'ausgefallen',
		none: 'kein Lauf'
	} as const;
	function stripRows(o: OpsInsights): HeatRow[] {
		return o.layers.map((l) => ({
			label: l.name,
			cells: l.runs.map((r, i) => ({
				tone: runTone[r],
				label: `Lauf ${i + 1} von ${l.runs.length} (älteste zuerst): ${runName[r]}`
			}))
		}));
	}
	const layerTone: Record<string, Tone> = { ok: 'ok', stale: 'warn', missing: 'err' };
	const layerLabel: Record<string, string> = { ok: 'Aktuell', stale: 'Veraltet', missing: 'Fehlt' };
	const roleLabel = { leader: 'Leader', follower: 'Follower' } as const;
	const stateTone: Record<string, Tone> = { running: 'ok', waiting: 'warn', restarting: 'warn' };
	const stateLabel = { running: 'Läuft', waiting: 'Wartet', restarting: 'Startet neu' } as const;
</script>

<PageHeader
	title="Betrieb"
	description="Aufnahme-Läufe, Verzögerung, Fehler, Cache und Replikate."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="strip" /><Skeletons /></div>
	{/snippet}
	{#snippet children(o)}
		{@const lab = bucketLabels(o.t, ctx.range)}
		{@const cacheTotal =
			sum(o.cache.memory) +
			sum(o.cache.joined) +
			sum(o.cache.db) +
			sum(o.cache.negative) +
			sum(o.cache.miss)}

		{#if o.restartPendingKeys.length}
			<div
				role="status"
				class="bg-warn-soft text-warn flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl px-4 py-3 text-[13px]"
			>
				<RotateCwIcon class="size-4 shrink-0" aria-hidden="true" />
				<p class="min-w-0 flex-1">
					<strong>Neustart nötig:</strong>
					<span class="font-mono text-xs">{o.restartPendingKeys.join(', ')}</span> wirkt erst nach einem
					Neustart.
				</p>
				<a href={resolve('/konfiguration')} class="font-medium underline underline-offset-2"
					>Zur Konfiguration</a
				>
			</div>
		{/if}

		<Panel
			title="Aufnahme-Läufe je Ebene"
			description="Ein Streifen je Ebene, jede Zelle ein erwarteter Lauf (älteste links)."
			info="Grün: Lauf erfolgreich. Orange: Lauf ausgefallen. Rot: Lauf mit Fehler. Die Höhe der Zelle wiederholt den Status, damit er nicht nur an der Farbe hängt."
		>
			{#if o.layers.length === 0}
				<EmptyState
					compact
					title="Noch keine Läufe"
					reason="Läufe erscheinen nach dem ersten Aufnahmezyklus der aktivierten Ebenen."
				/>
			{:else}
				<HeatStrip
					label="Aufnahme-Läufe je Ebene"
					rows={stripRows(o)}
					keys={[
						{ tone: 'ok', label: 'Erfolgreich' },
						{ tone: 'warn', label: 'Ausgefallen' },
						{ tone: 'err', label: 'Fehler' },
						{ tone: 'none', label: 'Kein Lauf' }
					]}
					axis={['älter', 'jetzt']}
				/>
			{/if}
		</Panel>

		<Panel
			title="Verzögerung gegenüber dem DWD-Lauf"
			flush
			info="Zeit zwischen Veröffentlichung beim DWD und Verfügbarkeit im Cache, Median und 95. Perzentil."
		>
			<DataTable
				caption="Ebenen mit Verzögerung"
				rows={o.layers}
				rowKey={(l) => l.id}
				columns={[
					{ key: 'name', label: 'Ebene' },
					{ key: 's', label: 'Status', cell: st },
					{
						key: 'last',
						label: 'Letzter Lauf',
						align: 'right',
						format: (l) => (l.lastRunAt ? formatAgo(l.lastRunAt, ctx.now) : '–')
					},
					{
						key: 'p50',
						label: 'Median',
						align: 'right',
						format: (l) => (l.delayP50Seconds === null ? '–' : formatDuration(l.delayP50Seconds))
					},
					{
						key: 'p95',
						label: 'p95',
						align: 'right',
						format: (l) => (l.delayP95Seconds === null ? '–' : formatDuration(l.delayP95Seconds))
					}
				]}
			/>
		</Panel>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
			<Panel
				title="Fehler"
				description="Serverfehler (5xx) und fehlgeschlagene Läufe, {rangeTitle}."
			>
				<XYChart
					label="Fehler {rangeTitle}"
					kind="bar"
					stacked
					categories={lab.categories}
					ticks={lab.ticks}
					height={200}
					series={[
						{ key: 'h', label: 'HTTP 5xx', values: o.errors.http5xx, color: 'err' },
						{ key: 'i', label: 'Ingest-Fehler', values: o.errors.ingest, color: 'warn' }
					]}
					format={formatNumber}
				/>
			</Panel>
			<Panel
				title="Cache"
				description="Wo Anfragen beantwortet wurden · Treffer {cacheTotal
					? formatPercent(1 - sum(o.cache.miss) / cacheTotal)
					: '–'}."
				info="Anteil der Abfragen je Cache-Stufe: Arbeitsspeicher, zusammengeführt, Datenbank, negativ (Eintrag fehlt bekanntermaßen) und Fehlgriff."
			>
				<XYChart
					label="Cache-Stufen {rangeTitle}"
					kind="area"
					stacked
					categories={lab.categories}
					ticks={lab.ticks}
					height={200}
					series={[
						{ key: 'mem', label: 'Speicher', values: o.cache.memory, color: 1 },
						{ key: 'joined', label: 'Zusammengeführt', values: o.cache.joined, color: 3 },
						{ key: 'db', label: 'Datenbank', values: o.cache.db, color: 2 },
						{ key: 'neg', label: 'Negativ', values: o.cache.negative, color: 4 },
						{ key: 'miss', label: 'Fehlgriff', values: o.cache.miss, color: 'warn' }
					]}
					format={formatNumber}
				/>
			</Panel>
		</div>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
			<Panel
				class="lg:col-span-3"
				title="Antwortzeit"
				description="Verteilung der Antwortzeiten im Zeitraum."
				info="Histogramm der Antwortzeit-Klassen. Gemessen wird die Zeit im Dienst, ohne Netzwerk."
			>
				{#if o.latency.buckets.length === 0}
					<EmptyState
						compact
						title="Noch keine Messwerte"
						reason="Antwortzeiten werden ab dem ersten Request erfasst."
					/>
				{:else}
					<XYChart
						label="Antwortzeiten"
						kind="bar"
						categories={o.latency.buckets.map((b) => b.label)}
						height={200}
						firstColumn="Klasse"
						series={[
							{
								key: 'c',
								label: 'Anfragen',
								values: o.latency.buckets.map((b) => b.count),
								color: 1
							}
						]}
						format={formatNumber}
					/>
					<dl class="mt-3 flex gap-6 text-[13px]">
						{#each [['Median', o.latency.p50], ['p95', o.latency.p95], ['p99', o.latency.p99]] as [k, v] (k)}
							<div>
								<dt class="text-muted-foreground">{k}</dt>
								<dd class="num text-base font-semibold">{v} ms</dd>
							</div>
						{/each}
					</dl>
				{/if}
			</Panel>
			<Panel
				class="lg:col-span-2"
				title="Replikate"
				description="Dienstinstanzen und Versand-Leader."
				flush
			>
				{#if o.replicas.length === 0}
					<div class="px-5 pb-5">
						<EmptyState
							compact
							icon={ServerOffIcon}
							title="Keine Replikate gemeldet"
							reason="Replikate melden sich beim Start; ohne Meldung läuft der Dienst vermutlich nicht."
						/>
					</div>
				{:else}
					<DataTable
						caption="Replikate"
						rows={o.replicas}
						rowKey={(r) => r.slot}
						columns={[
							{ key: 'slot', label: 'Slot', format: (r) => `Replikat ${r.slot}` },
							{ key: 'role', label: 'Rolle', format: (r) => roleLabel[r.role] },
							{ key: 'state', label: 'Zustand', cell: rs },
							{
								key: 'up',
								label: 'Laufzeit',
								align: 'right',
								format: (r) => formatDuration(r.uptimeSeconds)
							}
						]}
					/>
				{/if}
			</Panel>
		</div>
	{/snippet}
</Loadable>

{#snippet st(l: OpsLayer)}
	<StatusBadge tone={layerTone[l.status]} label={layerLabel[l.status]} />
{/snippet}
{#snippet rs(r: Replica)}
	<StatusBadge tone={stateTone[r.state]} label={stateLabel[r.state]} />
{/snippet}
