<script lang="ts">
	import EmptyState from '#lib/design/EmptyState.svelte';
	import BellOffIcon from '@lucide/svelte/icons/bell-off';
	import RankBars from '#lib/charts/RankBars.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import { formatDuration, formatNumber, formatPercent } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, ratio, sum } from '#lib/insights/series.js';

	const res = live((r) => insights.push(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');
	const toneLabel = { ok: 'Erfüllt', warn: 'Prüfen', err: 'Fehlt' } as const;
</script>

<PageHeader
	title="Push und Live Activities"
	description="Von der Auswertung bis zur Zustellung: wo geht etwas verloren, und warum startet eine Live Activity nicht?"
/>

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="kpis" /><Skeletons kind="list" /></div>
	{/snippet}
	{#snippet children(o)}
		{@const lab = bucketLabels(o.t, ctx.range)}
		{@const delivered = sum(o.delivery.delivered)}
		{@const failed = sum(o.delivery.failed)}
		{@const first = o.funnel[0]?.count ?? 0}

		{#if o.funnel.length === 0}
			<Panel>
				<EmptyState
					icon={BellOffIcon}
					title="Noch keine Push-Daten"
					reason="Push ist möglicherweise deaktiviert (PUSH_ENABLED) oder es gab im Zeitraum keine Auswertung. Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden)."
				/>
			</Panel>
		{:else}
			<section
				aria-label="Kennzahlen {rangeTitle}"
				class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4"
			>
				<Kpi
					label="Versandstatus"
					value={o.paused ? 'Pausiert' : 'Aktiv'}
					tone={o.paused ? 'warn' : 'ok'}
					hint="Pausieren in der Konfiguration"
				/>
				<Kpi
					label="Zustellquote"
					value={formatPercent(ratio(delivered, failed))}
					tone={(ratio(delivered, failed) ?? 1) >= 0.95 ? 'ok' : 'warn'}
					hint="{formatNumber(delivered)} angenommen, {formatNumber(failed)} fehlgeschlagen"
				/>
				<Kpi
					label="Warteschlange"
					value={formatNumber(o.outbox.pending)}
					tone={o.outbox.failed > 0 ? 'warn' : 'ok'}
					hint="{o.outbox.oldestAgeSeconds === null
						? 'leer'
						: `ältester ${formatDuration(o.outbox.oldestAgeSeconds)}`}, {o.outbox
						.failed} endgültig fehlgeschlagen"
				/>
				<Kpi
					label="Live Activities gestartet"
					value={formatNumber(sum(o.lifecycle.started))}
					series={o.lifecycle.started}
					goodWhen="none"
				/>
			</section>

			<Panel
				title="Voraussetzungen für Live Activities"
				description="Prüfliste: was muss stimmen, damit eine Live Activity startet."
				info="Die Liste fasst Zustände aus der Datenbank zusammen (Start-Token vorhanden, Umgebung passt, Warteschlange gesund). Einzelne Geräte prüfst du unter „Geräte“."
			>
				<ul class="divide-y">
					{#each o.checklist as c (c.id)}
						<li
							class="flex flex-col gap-1 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-start sm:gap-4"
						>
							<div class="sm:w-24 sm:shrink-0">
								<StatusBadge tone={c.tone} label={toneLabel[c.tone]} />
							</div>
							<div class="min-w-0">
								<p class="text-sm font-medium">{c.label}</p>
								<p class="text-muted-foreground text-[13px]">{c.detail}</p>
							</div>
						</li>
					{/each}
				</ul>
			</Panel>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
				<Panel
					title="Trichter"
					description="Von der Auswertung bis zur Annahme durch APNs."
					info="Jede Stufe zeigt, wie viele der Vorstufe übrig bleiben. Der große Abfall zwischen Auslöser und „Regen erwartet“ ist normal: meist regnet es nicht."
				>
					<RankBars
						label="Push-Trichter"
						format={formatNumber}
						items={o.funnel.map((f) => ({
							label: f.label,
							value: f.count,
							note: first ? formatPercent(f.count / first) : ''
						}))}
					/>
				</Panel>
				<Panel
					title="Übersprungen"
					description="Warum eine mögliche Meldung nicht gesendet wurde."
					info="Überspringgründe sind gewollt: Sperrzeit und Hysterese verhindern Dauerbenachrichtigungen, „Platz belegt“ heißt, dass bereits eine Live Activity läuft."
				>
					<RankBars
						label="Überspringgründe"
						color={2}
						format={formatNumber}
						items={o.skipped.map((s) => ({ label: s.label, value: s.count }))}
					/>
				</Panel>
			</div>

			<Panel
				title="Versandbilanz"
				description="Angenommene und fehlgeschlagene Zustellungen, {rangeTitle}."
			>
				<XYChart
					label="Versandbilanz {rangeTitle}"
					kind="bar"
					stacked
					categories={lab.categories}
					ticks={lab.ticks}
					height={210}
					series={[
						{ key: 'd', label: 'Angenommen', values: o.delivery.delivered, color: 1 },
						{ key: 'f', label: 'Fehlgeschlagen', values: o.delivery.failed, color: 'err' }
					]}
					format={formatNumber}
				/>
			</Panel>

			<Panel
				title="Lebenszyklus der Live Activities"
				description="Starts, Aktualisierungen und Enden."
			>
				<XYChart
					label="Lebenszyklus {rangeTitle}"
					kind="line"
					categories={lab.categories}
					ticks={lab.ticks}
					height={200}
					series={[
						{ key: 's', label: 'Gestartet', values: o.lifecycle.started, color: 1 },
						{ key: 'u', label: 'Aktualisiert', values: o.lifecycle.updated, color: 3 },
						{ key: 'e', label: 'Beendet', values: o.lifecycle.ended, color: 2 }
					]}
					format={formatNumber}
				/>
			</Panel>

			<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
				<Panel title="APNs-Fehler" description="Nach Grund." flush>
					<DataTable
						caption="APNs-Fehler nach Grund"
						rows={o.apnsErrors}
						rowKey={(e) => e.key}
						empty="Keine Fehler im Zeitraum."
						columns={[
							{ key: 'label', label: 'Grund', class: 'font-mono text-xs' },
							{
								key: 'count',
								label: 'Anzahl',
								align: 'right',
								format: (e) => formatNumber(e.count)
							}
						]}
					/>
				</Panel>
				<Panel
					title="Ungültig gewordene Token"
					description="Von APNs als ungültig gemeldet und entfernt."
					flush
				>
					<DataTable
						caption="Ungültige Token nach Art"
						rows={o.invalidated}
						rowKey={(e) => e.key}
						empty="Keine Token entfernt."
						columns={[
							{ key: 'label', label: 'Tokenart' },
							{
								key: 'count',
								label: 'Anzahl',
								align: 'right',
								format: (e) => formatNumber(e.count)
							}
						]}
					/>
				</Panel>
			</div>
		{/if}
	{/snippet}
</Loadable>
