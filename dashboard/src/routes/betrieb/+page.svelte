<script lang="ts">
	import ServerOffIcon from '@lucide/svelte/icons/server-off';
	import Trash2Icon from '@lucide/svelte/icons/trash-2';
	import HeatStrip, { type HeatRow } from '#lib/charts/HeatStrip.svelte';
	import RankBars from '#lib/charts/RankBars.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import {
		formatBytes,
		formatDuration,
		formatMs,
		formatNumber,
		formatPercent,
		formatTime
	} from '#lib/format.js';
	import { describeError, insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import NotCollected from '#lib/insights/NotCollected.svelte';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, unpack } from '#lib/insights/series.js';
	import { layerName, levelLabel, levelTone, routeLabel } from '#lib/insights/text.js';
	import type { OpsInsights, OpsLayer } from '#lib/insights/types.js';

	const res = live((r) => insights.ops(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const runTone = { ok: 'ok', error: 'err', missed: 'warn' } as const;
	const runName = { ok: 'erfolgreich', error: 'Fehler', missed: 'ausgefallen' } as const;
	function stripRows(o: OpsInsights): HeatRow[] {
		return o.layers
			.filter((l) => l.enabled)
			.map((l) => ({
				label: layerName(l.id),
				cells:
					l.runs.length === 0
						? [{ tone: 'none' as const, label: 'Noch kein Lauf erfasst' }]
						: l.runs.map((r) => ({
								tone: runTone[r.result] ?? ('none' as const),
								label: `${formatTime(r.slot, false)} UTC: ${runName[r.result] ?? r.result}`
							}))
			}));
	}

	const leLabel: Record<string, string> = {
		'10ms': '≤ 10 ms',
		'50ms': '≤ 50 ms',
		'200ms': '≤ 200 ms',
		'1s': '≤ 1 s',
		inf: '> 1 s'
	};
	const leOrder = ['10ms', '50ms', '200ms', '1s', 'inf'];
	function histogram(o: OpsInsights) {
		return leOrder.map((le) => ({
			label: leLabel[le],
			count: (o.latency ?? []).reduce(
				(s, r) => s + (r.buckets.find((b) => b.le === le)?.count ?? 0),
				0
			)
		}));
	}

	let confirmOpen = $state(false);
	let busy = $state(false);
	async function clearCache(): Promise<void> {
		busy = true;
		try {
			await insights.clearCache('all');
			toast.success(
				'Cache wird geleert',
				'Replikate leeren ihn beim nächsten Nachladen (höchstens 30 Sekunden).'
			);
			confirmOpen = false;
		} catch (e) {
			toast.error('Cache konnte nicht geleert werden', describeError(e));
		} finally {
			busy = false;
		}
	}
	const dash = (v: number | null, f: (n: number) => string) => (v === null ? '–' : f(v));
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
		{@const err = unpack(o.errors.status5xx.series)}
		{@const ing = unpack(o.errors.ingestErrors)}
		{@const lab = bucketLabels(err.t, o.errors.status5xx.series.resolution)}
		{@const hit = unpack(o.cache.series)}
		{@const labHit = bucketLabels(hit.t, o.cache.series.resolution)}
		{@const hist = histogram(o)}
		{@const rows = stripRows(o)}

		<Panel
			title="Aufnahme-Läufe je Ebene"
			description="Ein Streifen je Ebene, jede Zelle ein erwarteter Lauf der letzten 24 Stunden (älteste links)."
			info="Grün: Lauf erfolgreich. Orange: Lauf ausgefallen. Rot: Lauf mit Fehler. Die Höhe der Zelle wiederholt den Status, damit er nicht nur an der Farbe hängt."
		>
			{#if rows.length === 0}
				<EmptyState
					compact
					title="Keine aktivierte Ebene"
					reason="Aktiviere Ebenen in der Konfiguration (LAYERS), dann erscheinen hier ihre Läufe."
				/>
			{:else}
				<HeatStrip
					label="Aufnahme-Läufe je Ebene"
					{rows}
					keys={[
						{ tone: 'ok', label: 'Erfolgreich' },
						{ tone: 'warn', label: 'Ausgefallen' },
						{ tone: 'err', label: 'Fehler' },
						{ tone: 'none', label: 'Kein Lauf' }
					]}
					axis={['vor 24 h', 'jetzt']}
				/>
			{/if}
		</Panel>

		<Panel
			title="Ebenen im Detail"
			flush
			info="Alter: Zeit seit der Veröffentlichung des jüngsten Laufs. Verzögerung: Zeit zwischen Veröffentlichung beim DWD und Verfügbarkeit im Cache (Median und 95. Perzentil)."
		>
			<DataTable
				caption="Ebenen mit Alter und Verzögerung"
				rows={o.layers.filter((l) => l.enabled)}
				rowKey={(l) => l.id}
				columns={[
					{ key: 'name', label: 'Ebene', format: (l) => layerName(l.id) },
					{ key: 's', label: 'Status', cell: st },
					{
						key: 'age',
						label: 'Alter',
						align: 'right',
						format: (l) => dash(l.ageSeconds, formatDuration)
					},
					{
						key: 'cad',
						label: 'Takt',
						align: 'right',
						format: (l) => formatDuration(l.cadenceSeconds)
					},
					{
						key: 'p50',
						label: 'Verzögerung Median',
						align: 'right',
						format: (l) => dash(l.lag.p50Seconds, formatDuration)
					},
					{
						key: 'p95',
						label: 'p95',
						align: 'right',
						format: (l) => dash(l.lag.p95Seconds, formatDuration)
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
						{ key: 'h', label: 'HTTP 5xx', values: err.v, color: 'err' },
						{
							key: 'i',
							label: 'Ingest-Fehler',
							values: ing.v.length === err.v.length ? ing.v : err.v.map(() => null),
							color: 'warn'
						}
					]}
					format={formatNumber}
				/>
				{#if o.errors.status5xx.byRoute.length}
					<p class="text-muted-foreground mt-4 mb-2 text-[12px] font-medium">5xx nach Route</p>
					<RankBars
						label="5xx nach Route"
						color="err"
						format={formatNumber}
						items={o.errors.status5xx.byRoute.map((r) => ({
							label: routeLabel(r.route),
							value: r.count
						}))}
					/>
				{/if}
			</Panel>

			<Panel
				title="Cache"
				description="Treffer {dash(o.cache.hitRatio, formatPercent)} · {formatNumber(
					o.cache.dbReads
				)} Datenbank-Lesezugriffe."
			>
				{#snippet actions()}
					<Button variant="outline" size="sm" onclick={() => (confirmOpen = true)}
						><Trash2Icon aria-hidden="true" />Leeren</Button
					>
				{/snippet}
				<XYChart
					label="Cache-Quote {rangeTitle}"
					kind="line"
					zero={false}
					yMax={1}
					categories={labHit.categories}
					ticks={labHit.ticks}
					height={170}
					series={[{ key: 'hit', label: 'Treffer', values: hit.v, color: 3 }]}
					format={formatPercent}
					axisFormat={formatPercent}
				/>
				<div class="mt-4">
					<RankBars
						label="Cache-Kennzahlen"
						max={1}
						color={3}
						items={[
							...(o.cache.hitRatioRadar === null
								? []
								: [
										{
											label: 'Treffer Radar',
											value: o.cache.hitRatioRadar,
											display: formatPercent(o.cache.hitRatioRadar)
										}
									]),
							...(o.cache.hitRatioLayer === null
								? []
								: [
										{
											label: 'Treffer Zusatzebenen',
											value: o.cache.hitRatioLayer,
											display: formatPercent(o.cache.hitRatioLayer)
										}
									]),
							...(o.cache.negativeShare === null
								? []
								: [
										{
											label: 'Negativ-Treffer (Aufnahme fehlt bekanntermaßen)',
											value: o.cache.negativeShare,
											display: formatPercent(o.cache.negativeShare),
											color: 5 as const
										}
									]),
							...(o.cache.joinedShare === null
								? []
								: [
										{
											label: 'Zusammengeführt (gleichzeitige Anfragen)',
											value: o.cache.joinedShare,
											display: formatPercent(o.cache.joinedShare),
											color: 5 as const
										}
									]),
							...(o.cache.fill
								? [
										{
											label: 'Speicher belegt',
											value: o.cache.fill.bytes / o.cache.fill.maxBytes,
											display: formatPercent(o.cache.fill.bytes / o.cache.fill.maxBytes),
											note: `${formatBytes(o.cache.fill.bytes)} von ${formatBytes(o.cache.fill.maxBytes)}`,
											color: 2 as const
										}
									]
								: [])
						]}
					/>
				</div>
			</Panel>
		</div>

		<div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
			<Panel
				class="lg:col-span-3"
				title="Antwortzeit"
				description="Verteilung über alle Routen, 24 Stunden."
				info="Histogramm der Antwortzeit-Klassen. Gemessen wird die Zeit im Dienst, ohne Netzwerk. Perzentile sind aus Klassen geschätzt (Obergrenze der Klasse)."
			>
				{#if o.latency === null}
					<NotCollected what="Antwortzeiten" />
				{:else}
					<XYChart
						label="Antwortzeiten"
						kind="bar"
						categories={hist.map((b) => b.label)}
						height={190}
						firstColumn="Klasse"
						series={[{ key: 'c', label: 'Anfragen', values: hist.map((b) => b.count), color: 1 }]}
						format={formatNumber}
					/>
					<div class="mt-4 -mx-4 sm:-mx-5">
						<DataTable
							caption="Antwortzeit je Route"
							dense
							rows={o.latency}
							rowKey={(r) => r.route}
							columns={[
								{ key: 'route', label: 'Route', format: (r) => routeLabel(r.route) },
								{
									key: 'p50',
									label: 'Median',
									align: 'right',
									format: (r) => dash(r.p50Ms, formatMs)
								},
								{
									key: 'p95',
									label: 'p95',
									align: 'right',
									format: (r) => dash(r.p95Ms, formatMs)
								},
								{ key: 'p99', label: 'p99', align: 'right', format: (r) => dash(r.p99Ms, formatMs) }
							]}
						/>
					</div>
				{/if}
			</Panel>

			<Panel
				class="lg:col-span-2"
				title="Replikate"
				description="Instanzen und Versand-Leader · Generation {o.generation}."
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
						rowKey={(r) => r.id}
						columns={[
							{ key: 'id', label: 'Replikat', class: 'font-mono text-xs' },
							{ key: 'role', label: 'Rolle', cell: role },
							{ key: 'level', label: 'Zustand', cell: lv },
							{
								key: 'age',
								label: 'Laufzeit',
								align: 'right',
								format: (r) => formatDuration(r.ageSeconds)
							}
						]}
					/>
				{/if}
				<p class="text-muted-foreground px-5 py-3 text-[12px]">
					{#if o.leader?.holder}Leader-Sperre noch {dash(
							o.leader.leaseSecondsLeft,
							formatDuration
						)}{#if o.leader.changes24h !== null}
							· {o.leader.changes24h} Wechsel in 24 h{/if}{:else if o.leader}Kein Leader.{:else}Leader
						nicht ermittelt.{/if}
					{#if o.db}· Datenbank-Pool {dash(o.db.poolUsage, formatPercent)}{/if}
				</p>
			</Panel>
		</div>
	{/snippet}
</Loadable>

<ConfirmDialog
	bind:open={confirmOpen}
	title="Cache leeren?"
	description="Alle Replikate leeren ihren Arbeitsspeicher-Cache beim nächsten Nachladen (höchstens 30 Sekunden). Anfragen laufen danach kurz verstärkt gegen die Datenbank."
	confirmLabel="Cache leeren"
	{busy}
	onconfirm={clearCache}
/>

{#snippet st(l: OpsLayer)}
	<StatusBadge tone={levelTone(l.level)} label={levelLabel[l.level]} />
{/snippet}
{#snippet lv(r: OpsInsights['replicas'][number])}
	<StatusBadge tone={levelTone(r.level)} label={levelLabel[r.level]} />
{/snippet}
{#snippet role(r: OpsInsights['replicas'][number])}
	{r.isLeader ? 'Leader' : 'Follower'}
{/snippet}
