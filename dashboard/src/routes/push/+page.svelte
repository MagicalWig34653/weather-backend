<script lang="ts">
	import BellOffIcon from '@lucide/svelte/icons/bell-off';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import RankBars from '#lib/charts/RankBars.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { ctx, RANGES } from '#lib/design/context.svelte.js';
	import { formatDuration, formatNumber, formatPercent } from '#lib/format.js';
	import { describeError, insights } from '#lib/insights/api.js';
	import { live } from '#lib/insights/live.svelte.js';
	import NotCollected from '#lib/insights/NotCollected.svelte';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { bucketLabels, unpack } from '#lib/insights/series.js';
	import {
		apnsKindName,
		capName,
		causeName,
		eventName,
		invalidationName,
		outcomeName,
		prerequisiteDetail,
		prerequisiteName,
		rejectName,
		skipName,
		triggerName
	} from '#lib/insights/text.js';
	import type { Bucket } from '#lib/insights/types.js';

	const res = live((r) => insights.push(r));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.phrase ?? '');

	const supp = (b: Bucket[], names: Record<string, string> = {}) =>
		b.map((x) => ({
			label: names[x.key] ?? x.key,
			value: x.count ?? 0,
			display: x.suppressed ? `< 5` : undefined
		}));
	const ageNames = {
		lt1d: 'unter 1 Tag',
		lt7d: '1 bis 7 Tage',
		lt30d: '7 bis 30 Tage',
		older: 'älter'
	};
	const apiLe: Record<string, string> = {
		'50ms': '≤ 50 ms',
		'200ms': '≤ 200 ms',
		'1s': '≤ 1 s',
		inf: '> 1 s'
	};

	let confirmOpen = $state(false);
	let busy = $state(false);
	let wantPause = $state(true);
	function ask(pause: boolean): void {
		wantPause = pause;
		confirmOpen = true;
	}
	async function applyPause(): Promise<void> {
		busy = true;
		try {
			await insights.setPaused(wantPause);
			toast.success(wantPause ? 'Versand pausiert' : 'Versand fortgesetzt');
			confirmOpen = false;
			ctx.refresh();
		} catch (e) {
			toast.error('Aktion fehlgeschlagen', describeError(e));
		} finally {
			busy = false;
		}
	}
</script>

<PageHeader
	title="Push und Live Activities"
	description="Von der Auswertung bis zur Zustellung: wo geht etwas verloren, und warum startet eine Live Activity nicht?"
>
	{#snippet actions()}
		{#if res.data?.pushEnabled}
			{#if res.data.pushPaused}
				<Button variant="outline" onclick={() => ask(false)}
					><PlayIcon aria-hidden="true" />Versand fortsetzen</Button
				>
			{:else}
				<Button variant="outline" onclick={() => ask(true)}
					><PauseIcon aria-hidden="true" />Versand pausieren</Button
				>
			{/if}
		{/if}
	{/snippet}
</PageHeader>

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="kpis" /><Skeletons kind="list" /></div>
	{/snippet}
	{#snippet children(o)}
		{@const created = unpack(o.registrations?.created ?? null)}
		{@const deleted = unpack(o.registrations?.deleted ?? null)}
		{@const labReg = bucketLabels(created.t, o.resolution)}

		{#if !o.pushEnabled}
			<Panel>
				<EmptyState
					icon={BellOffIcon}
					title={o.pushState === 'unknown' ? 'Push-Zustand unbekannt' : 'Push ist ausgeschaltet'}
					reason={o.pushState === 'unknown'
						? 'Kein Radar-Replikat hat sich in den letzten Minuten gemeldet; ob Push läuft, ist nicht bekannt. Prüfe die Replikate unter Betrieb.'
						: 'Der Dienst verschickt nichts (PUSH_ENABLED=false). Schalte Push in der Konfiguration ein und starte neu; Zähler erscheinen danach nach höchstens 60 Sekunden.'}
				/>
			</Panel>
		{:else}
			<section
				aria-label="Kennzahlen {rangeTitle}"
				class="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4"
			>
				<Kpi
					label="Versandstatus"
					value={o.pushPaused ? 'Pausiert' : 'Aktiv'}
					tone={o.pushPaused ? 'warn' : 'ok'}
					hint={o.pushPaused
						? 'Auswertung läuft, es wird nichts gesendet'
						: 'Pausieren oben rechts'}
				/>
				<Kpi
					label="Zustellquote"
					value={o.delivery?.ratio == null ? '–' : formatPercent(o.delivery.ratio)}
					tone={o.delivery?.ratio == null ? undefined : o.delivery.ratio >= 0.95 ? 'ok' : 'warn'}
					hint={o.delivery
						? `${formatNumber(o.delivery.delivered)} von ${formatNumber(o.delivery.sent)} angenommen`
						: 'noch nicht erhoben'}
				/>
				<Kpi
					label="Warteschlange"
					value={o.outbox ? formatNumber(o.outbox.waiting) : '–'}
					tone={o.outbox ? (o.outbox.droppedOrExpired24h > 0 ? 'warn' : 'ok') : undefined}
					hint={o.outbox
						? `${o.outbox.oldestAgeSeconds === null ? 'leer' : `ältester ${formatDuration(o.outbox.oldestAgeSeconds)}`}, ${o.outbox.retrying} in Wiederholung`
						: 'noch nicht erhoben'}
				/>
				<Kpi
					label="Aktive Live Activities"
					value={o.lifecycle ? formatNumber(o.lifecycle.activeNow) : '–'}
					hint={o.lifecycle
						? `${o.lifecycle.reservationsOpen} Reservierungen offen`
						: 'noch nicht erhoben'}
				/>
			</section>

			<Panel
				title="Voraussetzungen"
				description="Prüfliste: was muss stimmen, damit Mitteilungen und Live Activities ankommen."
				info="Die Liste fasst Zustände aus Konfiguration und Datenbank zusammen. Einzelne Geräte prüfst du unter „Geräte“."
			>
				<ul class="divide-y">
					{#each o.prerequisites as p (p.key)}
						<li
							class="flex flex-col gap-1 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-start sm:gap-4"
						>
							<div class="sm:w-24 sm:shrink-0">
								<StatusBadge tone={p.ok ? 'ok' : 'warn'} label={p.ok ? 'Erfüllt' : 'Prüfen'} />
							</div>
							<div class="min-w-0">
								<p class="text-sm font-medium">{prerequisiteName[p.key] ?? p.key}</p>
								{#if p.detail}<p class="text-muted-foreground text-[13px]">
										{prerequisiteDetail[p.detail] ?? p.detail}
									</p>{/if}
							</div>
						</li>
					{/each}
				</ul>
			</Panel>

			{#if o.funnel}
				{@const f = o.funnel}
				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					<Panel
						title="Installationen und Token"
						description="Wie viele können überhaupt etwas empfangen?"
						info="Von allen Installationen haben nur die mit Start-Token die Chance, dass eine Live Activity von außen gestartet wird."
					>
						<RankBars
							label="Installationen und Token"
							format={formatNumber}
							items={[
								{ label: 'Installationen', value: f.installations.total },
								{ label: 'Aktiv in 30 Tagen', value: f.installations.active30d },
								{ label: 'Aktiv in 7 Tagen', value: f.installations.active7d },
								{ label: 'Aktiv in 24 Stunden', value: f.installations.active1d },
								{ label: 'Mit Geräte-Token', value: f.tokens.withDeviceToken, color: 3 },
								{ label: 'Mit Start-Token', value: f.tokens.withStartToken, color: 3 }
							]}
							max={f.installations.total}
						/>
					</Panel>
					<Panel
						title="Abos"
						description="Aktivierte Abos und Live-Activity-Abos."
						info="„Inkonsistent“ zählt Abos, deren Zustände sich widersprechen (z. B. Live Activity an, aber kein Start-Token)."
					>
						<RankBars
							label="Abos"
							format={formatNumber}
							max={f.subscriptions.total}
							items={[
								{ label: 'Abos', value: f.subscriptions.total },
								{ label: 'Aktiviert', value: f.subscriptions.enabled },
								{ label: 'Mit Live Activity', value: f.subscriptions.liveActivity, color: 2 },
								{
									label: 'Live Activity mit Start-Token',
									value: f.subscriptions.liveActivityWithStartToken,
									color: 2
								}
							]}
						/>
						{#if f.subscriptions.inconsistent > 0}
							<p class="text-warn bg-warn-soft mt-4 rounded-lg px-3 py-2 text-[13px]">
								{f.subscriptions.inconsistent} Abos mit widersprüchlichem Zustand.
							</p>
						{/if}
						<p class="text-muted-foreground mt-4 mb-2 text-[12px] font-medium">
							Alter der Start-Token
						</p>
						<RankBars
							label="Alter der Start-Token"
							color={5}
							format={formatNumber}
							items={supp(f.tokens.startTokenAge, ageNames)}
						/>
					</Panel>
				</div>
			{/if}

			{#if o.triggers === null}
				<Panel
					title="Auslöser, Überspringgründe, Zustellung"
					description="Zählerbasierte Auswertung der Push-Pipeline."
				>
					<NotCollected
						what="Auslöser, Überspringgründe, APNs-Fehler, Lebenszyklus und Zustellbilanz"
					/>
				</Panel>
			{:else}
				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					<Panel title="Auslöser" description="Wodurch eine Auswertung eine Meldung anstieß.">
						<RankBars
							label="Auslöser"
							format={formatNumber}
							items={o.triggers.map((t) => ({
								label: triggerName[t.trigger] ?? t.trigger,
								value: t.count
							}))}
						/>
					</Panel>
					<Panel
						title="Übersprungen"
						description="Warum eine mögliche Meldung nicht gesendet wurde."
						info="Sperrzeit und Hysterese verhindern Dauerbenachrichtigungen; „Platz belegt“ heißt, dass bereits eine Live Activity läuft; „Start-Token fehlt“ ist der häufigste Grund, warum Live Activities nie starten."
					>
						<RankBars
							label="Überspringgründe"
							color={2}
							format={formatNumber}
							items={(o.skipped ?? []).map((s) => ({
								label: `${skipName[s.reason] ?? s.reason} · ${triggerName[s.trigger] ?? s.trigger}`,
								value: s.count
							}))}
						/>
					</Panel>
				</div>

				{#if o.delivery}
					<Panel
						title="Zustellbilanz"
						description="Ergebnis der Sendungen {rangeTitle}, Ø {o.delivery.avgAttempts ??
							'–'} Versuche je Sendung."
					>
						<RankBars
							label="Zustellbilanz"
							format={formatNumber}
							items={[
								{ label: 'Von APNs angenommen', value: o.delivery.delivered, color: 'ok' },
								{ label: 'Abgelehnt', value: o.delivery.rejected, color: 'err' },
								{ label: 'Verworfen', value: o.delivery.dropped, color: 5 },
								{ label: 'In Wiederholung', value: o.delivery.retry, color: 'warn' }
							]}
						/>
					</Panel>
				{/if}

				{#if o.lifecycle}
					<Panel
						title="Lebenszyklus der Live Activities"
						description="Ereignisse nach Ergebnis · {o.lifecycle
							.reservationsExpired} Reservierungen abgelaufen."
						flush
					>
						<DataTable
							caption="Live-Activity-Ereignisse"
							rows={o.lifecycle.events}
							rowKey={(e) => e.event + e.outcome}
							columns={[
								{ key: 'event', label: 'Ereignis', format: (e) => eventName[e.event] ?? e.event },
								{
									key: 'outcome',
									label: 'Ergebnis',
									format: (e) => outcomeName[e.outcome] ?? e.outcome
								},
								{
									key: 'count',
									label: 'Anzahl',
									align: 'right',
									format: (e) => formatNumber(e.count)
								}
							]}
						/>
					</Panel>
				{/if}

				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					<Panel title="APNs-Fehler" description="Nach Art und Grund." flush>
						<DataTable
							caption="APNs-Fehler"
							rows={o.apnsErrors ?? []}
							rowKey={(e) => e.kind + e.reason + e.env}
							empty="Keine Fehler im Zeitraum."
							columns={[
								{
									key: 'reason',
									label: 'Grund',
									class: 'font-mono text-xs',
									format: (e) => e.reason
								},
								{
									key: 'kind',
									label: 'Art',
									format: (e) => `${apnsKindName[e.kind] ?? e.kind} (${e.env})`
								},
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
						description="Von APNs als ungültig gemeldet."
						flush
					>
						<DataTable
							caption="Ungültige Token"
							rows={o.tokenInvalidations ?? []}
							rowKey={(e) => e.kind + e.cause}
							empty="Keine Token entfernt."
							columns={[
								{
									key: 'kind',
									label: 'Tokenart',
									format: (e) => invalidationName[e.kind] ?? e.kind
								},
								{ key: 'cause', label: 'Ursache', format: (e) => causeName[e.cause] ?? e.cause },
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

				<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
					{#if o.registrations}
						<Panel
							title="Registrierungen"
							description="Neue und gelöschte Installationen · nach 7 Tagen noch aktiv: {o
								.registrations.retained7dRatio === null
								? '–'
								: formatPercent(o.registrations.retained7dRatio)}."
						>
							<XYChart
								label="Registrierungen {rangeTitle}"
								kind="bar"
								categories={labReg.categories}
								ticks={labReg.ticks}
								height={190}
								series={[
									{ key: 'c', label: 'Neu', values: created.v, color: 1 },
									{ key: 'd', label: 'Gelöscht', values: deleted.v, color: 5 }
								]}
								format={formatNumber}
							/>
						</Panel>
					{/if}
					{#if o.rejects}
						<Panel
							title="Abgewiesene Registrierungen"
							description="Grenzen, an die Installationen stießen."
						>
							<RankBars
								label="Abweisungen"
								color={2}
								format={formatNumber}
								items={o.rejects.map((r) => ({
									label: rejectName[r.code] ?? r.code,
									value: r.count
								}))}
							/>
						</Panel>
					{/if}
				</div>

				{#if o.timing}
					<Panel title="Laufzeiten" description="APNs-Sendedauer und Auswertung.">
						<RankBars
							label="APNs-Sendedauer"
							format={formatNumber}
							color={3}
							items={o.timing.apnsSendMs.map((b) => ({
								label: apiLe[b.le] ?? b.le,
								value: b.count
							}))}
						/>
						<p class="text-muted-foreground mt-4 text-[13px]">
							Auswertung p95: {o.timing.evalMsP95 === null
								? '–'
								: `${formatNumber(o.timing.evalMsP95)} ms`} · {o.timing.cellsChecked === null
								? '–'
								: formatNumber(o.timing.cellsChecked)} von höchstens {formatNumber(
								o.timing.cellsMax
							)} Zellen je Lauf.
						</p>
					</Panel>
				{/if}
			{/if}

			{#if o.caps}
				<Panel title="Grenzen" description="Füllgrad der Obergrenzen.">
					<RankBars
						label="Grenzen"
						max={1}
						color={3}
						items={o.caps.map((c) => ({
							label: capName(c.key),
							value: c.gauge.ratio,
							display: formatPercent(c.gauge.ratio),
							note: `${formatNumber(c.gauge.used)} von ${formatNumber(c.gauge.max)}`
						}))}
					/>
				</Panel>
			{/if}
		{/if}
	{/snippet}
</Loadable>

<ConfirmDialog
	bind:open={confirmOpen}
	title={wantPause ? 'Versand pausieren?' : 'Versand fortsetzen?'}
	description={wantPause
		? 'Die Auswertung läuft weiter, es wird aber nichts gesendet. Wartende Meldungen laufen nach 6 Stunden ab.'
		: 'Der Versand läuft wieder an. Meldungen, die in der Pause nicht abgelaufen sind, werden noch gesendet.'}
	confirmLabel={wantPause ? 'Pausieren' : 'Fortsetzen'}
	{busy}
	onconfirm={applyPause}
/>
