<script lang="ts">
	import { page } from '$app/state';
	import { untrack } from 'svelte';
	import DatabaseIcon from '@lucide/svelte/icons/database';
	import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
	import EraserIcon from '@lucide/svelte/icons/eraser';
	import LoaderIcon from '@lucide/svelte/icons/loader-circle';
	import { ApiError } from '#lib/api.js';
	import { session } from '#lib/session.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import Segmented from '#lib/design/Segmented.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import {
		formatAgo,
		formatBytes,
		formatDateTime,
		formatDuration,
		formatNumber
	} from '#lib/format.js';
	import { describeError, insights } from '#lib/insights/api.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import { Resource } from '#lib/resource.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import SlotPreview from '#lib/insights/SlotPreview.svelte';
	import {
		attemptText,
		cacheKindText,
		cacheStateText,
		layerName,
		layerReason,
		refreshErrorName,
		refreshResultText,
		refreshStatusText
	} from '#lib/insights/text.js';
	import type { CacheLayer, CacheSlot, RefreshJob } from '#lib/insights/types.js';

	const res = liveStatic(() => insights.cache());

	// ---- Auftraege: je Ebene der juengste Auftrag dieser Sitzung (Status per Polling)
	let jobs = $state<Record<string, RefreshJob>>({});
	const active = (l: string): boolean =>
		jobs[l] !== undefined && (jobs[l].status === 'queued' || jobs[l].status === 'running');
	const anyActive = $derived(Object.keys(jobs).some(active));

	async function track(job: { id: string; layer: string; createdAt: string }): Promise<void> {
		jobs[job.layer] = {
			id: job.id,
			layer: job.layer,
			status: 'queued',
			createdAt: job.createdAt,
			startedAt: null,
			finishedAt: null,
			result: null,
			error: null
		};
		const name = layerName(job.layer);
		const out = await insights.pollRefresh(job.id, (j) => {
			jobs[j.layer] = j;
		});
		if (out.kind === 'final') {
			const j = out.command;
			jobs[j.layer] = j;
			if (j.status === 'ok') toast.success(`${name}: Abruf abgeschlossen`, refreshResultText(j));
			else if (j.status === 'expired')
				toast.error(`${name}: nicht ausgeführt`, refreshErrorName(j.error ?? 'no_ingest_replica'));
			else toast.error(`${name}: Abruf fehlgeschlagen`, refreshErrorName(j.error));
			ctx.refresh();
		} else if (out.kind === 'timeout') {
			toast.error(`${name}: kein Ergebnis`, 'Nach 5 Minuten liegt kein Ergebnis vor.');
		} else {
			if (out.error instanceof ApiError && out.error.code === 'unauthorized') session.expire();
			toast.error(
				`${name}: Ergebnis unbekannt`,
				`${describeError(out.error)} Der Auftrag kann trotzdem laufen.`
			);
		}
	}

	let starting = $state(false);
	async function refresh(layer: string): Promise<void> {
		starting = true;
		try {
			const r = await insights.refreshCache(layer);
			toast.push(
				'info',
				'Abruf gestartet',
				`${r.jobs.length === 1 ? layerName(r.jobs[0].layer) : `${r.jobs.length} Ebenen`}: Ergebnis folgt …`,
				3000
			);
			await Promise.all(r.jobs.map((j) => track(j)));
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
			toast.error('Abruf nicht gestartet', describeError(e));
		} finally {
			starting = false;
		}
	}

	let confirmAll = $state(false);
	let confirmClear = $state(false);
	let clearing = $state(false);
	async function clearProcess(): Promise<void> {
		clearing = true;
		try {
			await insights.clearCache('all');
			toast.success(
				'Prozess-Cache wird geleert',
				'Replikate leeren ihn beim nächsten Nachladen (höchstens 30 Sekunden).'
			);
			confirmClear = false;
		} catch (e) {
			toast.error('Cache konnte nicht geleert werden', describeError(e));
		} finally {
			clearing = false;
		}
	}

	// ---- Ebene, Slots, Vorschau
	let layer = $state(untrack(() => page.url.searchParams.get('layer') ?? 'radar'));
	let pageSlots = $state<CacheSlot[]>([]);
	let next = $state<string | null>(null);
	let loadingMore = $state(false);
	const slotsRes = new Resource(() => insights.cacheSlots(layer));
	let sel = $state(0);
	/** Aufsteigend (aeltester zuerst) fuer Slider und Liste; der Server liefert absteigend. */
	const asc = $derived([...pageSlots].reverse());

	$effect(() => {
		void layer;
		void ctx.tick;
		untrack(() => {
			const keep = asc[sel]?.slot;
			void slotsRes.load().then(() => {
				const d = slotsRes.data;
				if (!d || d.layer !== layer) return;
				pageSlots = d.slots;
				next = d.next;
				const i = keep ? [...d.slots].reverse().findIndex((s) => s.slot === keep) : -1;
				sel = i >= 0 ? i : Math.max(0, d.slots.length - 1);
			});
		});
		return () => slotsRes.cancel();
	});
	function pick(id: string): void {
		layer = id;
		pageSlots = [];
		next = null;
		sel = 0;
		const url = new URL(page.url.href);
		url.searchParams.set('layer', id);
		history.replaceState(history.state, '', url);
	}
	async function more(): Promise<void> {
		if (!next) return;
		loadingMore = true;
		try {
			const d = await insights.cacheSlots(layer, next);
			const keep = asc[sel]?.slot;
			pageSlots = [...pageSlots, ...d.slots];
			next = d.next;
			const i = keep ? asc.findIndex((s) => s.slot === keep) : -1;
			if (i >= 0) sel = i;
		} catch (e) {
			toast.error('Ältere Slots konnten nicht geladen werden', describeError(e));
		} finally {
			loadingMore = false;
		}
	}

	const tone = (s: string) => cacheStateText[s]?.tone ?? 'neutral';
	const stateLabel = (s: string) => cacheStateText[s]?.label ?? s;
	const span = (l: CacheLayer) =>
		l.oldestNominal && l.newestNominal
			? `${formatDateTime(l.oldestNominal)} bis ${formatDateTime(l.newestNominal)}`
			: '–';
</script>

<PageHeader
	title="Cache"
	description="Welche Karten die Datenbank und die Prozesse vorhalten, wie aktuell sie sind und was gerade im Bild steht."
>
	{#snippet actions()}
		<Button
			variant="outline"
			size="sm"
			disabled={starting || anyActive}
			onclick={() => (confirmAll = true)}
		>
			<RefreshCwIcon aria-hidden="true" />Alle neu abrufen
		</Button>
		<Button variant="outline" size="sm" onclick={() => (confirmClear = true)}>
			<EraserIcon aria-hidden="true" />Prozess-Cache leeren
		</Button>
	{/snippet}
</PageHeader>

<Loadable {res}>
	{#snippet skeleton()}
		<div class="space-y-6"><Skeletons kind="list" /><Skeletons /></div>
	{/snippet}
	{#snippet children(o)}
		{#if o.partial.includes('layers')}
			<p class="bg-warn-soft text-warn rounded-lg px-3 py-2 text-[13px]" role="status">
				Das Inventar der Ebenen konnte nicht vollständig gelesen werden (Teilausfall); die Tabelle
				zeigt nur, was verfügbar war.
			</p>
		{/if}
		{@const bad = o.layers.filter((l) => l.state === 'stale' || l.state === 'failed')}
		{#if bad.length > 0}
			<Panel
				title="Was ist auffällig?"
				description="Ebenen ohne frische Daten und der wahrscheinliche Grund."
			>
				<ul class="divide-y">
					{#each bad as l (l.id)}
						<li class="flex flex-col gap-1 py-3 first:pt-0 last:pb-0 sm:flex-row sm:gap-4">
							<div class="sm:w-32 sm:shrink-0">
								<StatusBadge tone={tone(l.state)} label={stateLabel(l.state)} />
							</div>
							<div class="min-w-0 flex-1">
								<p class="text-sm font-medium">{layerName(l.id)}</p>
								<p class="text-muted-foreground text-[13px] leading-5">{layerReason(l)}</p>
							</div>
						</li>
					{/each}
				</ul>
			</Panel>
		{/if}

		<Panel
			title="Ebenen in der Datenbank"
			flush
			info="Zählt nur veröffentlichte Läufe und Slots. Aktuell: höchstens das Dreifache des Takts seit der letzten Veröffentlichung (mindestens 15 Minuten). Veraltet: bis zum Zwölffachen. Ausgefallen: älter oder jüngster Versuch fehlgeschlagen. Die Schwellen sind im Server festgelegt."
		>
			<DataTable
				caption="Cache-Inventar je Ebene"
				rows={o.layers}
				rowKey={(l) => l.id}
				empty="Keine Ebenen gemeldet."
				columns={[
					{ key: 'name', label: 'Ebene', cell: nameCell },
					{ key: 'state', label: 'Zustand', cell: stateCell },
					{ key: 'span', label: 'Zeitspanne (Nominalzeit)', format: span },
					{ key: 'slots', label: 'Slots', align: 'right', format: (l) => formatNumber(l.slots) },
					{
						key: 'bytes',
						label: 'Größe',
						align: 'right',
						format: (l) => (l.bytes === null ? '–' : formatBytes(l.bytes))
					},
					{
						key: 'pub',
						label: 'Zuletzt veröffentlicht',
						format: (l) => formatAgo(l.latestPublishedAt, ctx.now)
					},
					{ key: 'try', label: 'Letzter Abruf', cell: attemptCell },
					{
						key: 'err',
						label: 'Fehler 24 h',
						align: 'right',
						format: (l) => (l.errors24h === null ? '–' : formatNumber(l.errors24h))
					},
					{ key: 'act', label: 'Aktion', cell: actionCell }
				]}
			/>
		</Panel>

		<Panel
			title="Prozess-Cache"
			description="Bilder im Arbeitsspeicher der Replikate, bereits abgerufene Bilder aus der Datenbank."
		>
			{#if o.process}
				<p class="text-sm">
					<span class="font-medium">Dieses Replikat:</span>
					{formatBytes(o.process.bytes)} von {formatBytes(o.process.maxBytes)}
					({formatNumber(o.process.entries)} Einträge).
				</p>
			{:else}
				<p class="text-muted-foreground text-sm">
					Der antwortende Dienst hat keinen Prozess-Cache; die Füllstände stehen unten je Replikat.
				</p>
			{/if}
			{#if o.replicas.length > 0}
				<ul class="text-muted-foreground mt-2 grid gap-1 text-[13px] sm:grid-cols-2">
					{#each o.replicas as r (r.id)}
						<li class="num">
							Replikat <span class="font-mono">{r.id}</span>:
							{r.cacheBytes === null
								? 'Füllstand nicht gemeldet'
								: `${formatBytes(r.cacheBytes)}${r.cacheMaxBytes ? ` von ${formatBytes(r.cacheMaxBytes)}` : ''}, ${formatNumber(r.cacheEntries ?? 0)} Einträge`}
						</li>
					{/each}
				</ul>
			{/if}
		</Panel>

		<Panel
			title="Slots und Vorschau"
			description="Gespeicherte Bilder der gewählten Ebene. Die Vorschau zeigt das Bild aus der Datenbank, nicht den Prozess-Cache."
		>
			<div class="mb-4 max-w-full overflow-x-auto">
				<Segmented
					label="Ebene für die Vorschau"
					value={layer}
					options={o.layers
						.filter((l) => l.slots > 0 || l.id === layer)
						.map((l) => ({ value: l.id, label: layerName(l.id), title: layerName(l.id) }))}
					onchange={pick}
				/>
			</div>
			<Loadable res={slotsRes} compact>
				{#snippet skeleton()}
					<Skeletons />
				{/snippet}
				{#snippet children(d)}
					{#if d.slots.length === 0 && pageSlots.length === 0}
						<EmptyState
							compact
							icon={DatabaseIcon}
							title="Keine Slots für {layerName(layer)}"
							reason="Für diese Ebene wurde noch nichts veröffentlicht. Mit „Neu abrufen“ lässt sich ein Lauf anstoßen."
						/>
					{:else}
						<SlotPreview {layer} slots={asc} bind:index={sel} />
						<div class="mt-5 max-h-96 overflow-y-auto rounded-lg border">
							<DataTable
								caption="Slots von {layerName(layer)}, neueste zuerst"
								dense
								rows={pageSlots}
								rowKey={(s) => s.slot + s.run}
								columns={[
									{ key: 'slot', label: 'Slot', cell: slotCell },
									{ key: 'run', label: 'Lauf', format: (s) => formatDateTime(s.run) },
									{ key: 'index', label: 'Nr.', align: 'right' },
									{
										key: 'bytes',
										label: 'Größe',
										align: 'right',
										format: (s) => formatBytes(s.bytes)
									},
									{
										key: 'pub',
										label: 'Veröffentlicht',
										format: (s) => (s.published ? formatDateTime(s.publishedAt) : 'nein')
									}
								]}
							/>
							{#if next}
								<div class="mt-3 text-center">
									<Button variant="outline" size="sm" onclick={more} disabled={loadingMore}>
										{loadingMore ? 'Lade …' : 'Ältere Slots laden'}
									</Button>
								</div>
							{/if}
						</div>
					{/if}
				{/snippet}
			</Loadable>
		</Panel>
	{/snippet}
</Loadable>

{#snippet nameCell(l: CacheLayer)}
	<span class="font-medium">{layerName(l.id)}</span>
	<span class="text-muted-foreground block text-[11px]"
		>{l.id} · {cacheKindText[l.kind] ?? l.kind} · Takt {formatDuration(l.cadenceSeconds)}</span
	>
{/snippet}
{#snippet stateCell(l: CacheLayer)}
	<StatusBadge tone={tone(l.state)} label={stateLabel(l.state)} />
{/snippet}
{#snippet attemptCell(l: CacheLayer)}
	{#if l.lastAttemptAt}
		<span>{attemptText[l.lastAttemptResult ?? ''] ?? '–'}</span>
		<span class="text-muted-foreground block text-[11px]"
			>{formatAgo(l.lastAttemptAt, ctx.now)}</span
		>
	{:else}–{/if}
{/snippet}
{#snippet actionCell(l: CacheLayer)}
	{@const job = jobs[l.id]}
	<div class="flex items-center gap-1.5">
		<Button
			variant="outline"
			size="sm"
			disabled={!l.enabled || active(l.id) || starting}
			onclick={() => void refresh(l.id)}
			aria-label="{layerName(l.id)} neu abrufen"
		>
			{#if active(l.id)}<LoaderIcon class="animate-spin" aria-hidden="true" />{:else}<RefreshCwIcon
					aria-hidden="true"
				/>{/if}
			{active(l.id) ? 'läuft …' : 'Neu abrufen'}
		</Button>
		<Button
			variant="ghost"
			size="sm"
			onclick={() => pick(l.id)}
			aria-pressed={layer === l.id}
			disabled={l.slots === 0}
		>
			Slots
		</Button>
	</div>
	{#if job}
		<span class="text-muted-foreground mt-1 block text-[11px]" role="status">
			Auftrag {refreshStatusText[job.status] ?? job.status}{job.status === 'ok'
				? `: ${refreshResultText(job)}`
				: job.status === 'failed' || job.status === 'expired'
					? `: ${refreshErrorName(job.error)}`
					: ''}
		</span>
	{/if}
{/snippet}
{#snippet slotCell(s: CacheSlot)}
	<button
		type="button"
		class="hover:underline {asc[sel]?.slot === s.slot && asc[sel]?.run === s.run
			? 'text-primary-ink font-semibold'
			: ''}"
		aria-current={asc[sel]?.slot === s.slot && asc[sel]?.run === s.run ? 'true' : undefined}
		onclick={() => (sel = asc.findIndex((x) => x.slot === s.slot && x.run === s.run))}
	>
		{formatDateTime(s.slot)}
	</button>
{/snippet}

<ConfirmDialog
	bind:open={confirmAll}
	title="Alle Ebenen neu abrufen?"
	description="Für jede aktivierte Ebene wird ein außerplanmäßiger Abruf bei DWD und EUMETSAT angestoßen. Es wird nur geholt, was fehlt. Pro Minute sind höchstens 6 Abrufe möglich."
	confirmLabel="Alle neu abrufen"
	busy={starting}
	onconfirm={async () => {
		confirmAll = false;
		await refresh('all');
	}}
/>
<ConfirmDialog
	bind:open={confirmClear}
	title="Prozess-Cache leeren?"
	description="Alle Replikate leeren ihren Arbeitsspeicher-Cache beim nächsten Nachladen (höchstens 30 Sekunden). Anfragen laufen danach kurz verstärkt gegen die Datenbank. Die gespeicherten Bilder bleiben erhalten."
	confirmLabel="Cache leeren"
	busy={clearing}
	onconfirm={clearProcess}
/>
