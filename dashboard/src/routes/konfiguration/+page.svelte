<script lang="ts">
	import { onMount } from 'svelte';
	import BellOffIcon from '@lucide/svelte/icons/bell-off';
	import PauseIcon from '@lucide/svelte/icons/pause';
	import PlayIcon from '@lucide/svelte/icons/play';
	import RotateCwIcon from '@lucide/svelte/icons/rotate-cw';
	import SearchIcon from '@lucide/svelte/icons/search';
	import { resolve } from '$app/paths';
	import { api } from '#lib/client.js';
	import { ApiError, type ConfigEntry, type ConfigValue, type RestartState } from '#lib/api.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import ConfigRow from '#lib/config/ConfigRow.svelte';
	import ThresholdRule from '#lib/config/ThresholdRule.svelte';
	import { THRESHOLD_GROUP, applyLabel, formatValue, groupEntries } from '#lib/config/form.js';
	import { thresholdRows, toInput, unitSuffix, RULES } from '#lib/config/thresholds.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { describeError, insights } from '#lib/insights/api.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { session } from '#lib/session.svelte.js';

	interface Loaded {
		revision: number;
		entries: ConfigEntry[];
		restart: RestartState;
	}
	const res = liveStatic<Loaded>(async () => {
		const [c, restart] = await Promise.all([api.config(), api.restartState()]);
		return { revision: c.revision, entries: c.entries, restart };
	});
	// Versandstatus kommt aus der Uebersicht (kein eigener Pause-Abruf im Vertrag).
	const pause = liveStatic(() => insights.overview('24h'));

	let query = $state('');
	let onlyChanged = $state(false);

	// ------------------------------------------------------------ Aenderungen mit Bestaetigung

	interface Change {
		entry: ConfigEntry;
		/** null: auf Standard zuruecksetzen. */
		value: ConfigValue;
		reset: boolean;
	}
	let pending = $state<Change[]>([]);
	let confirmOpen = $state(false);
	let busy = $state(false);
	let dialogError = $state<string | null>(null);

	function ask(changes: Change[]): void {
		pending = changes;
		dialogError = null;
		confirmOpen = true;
	}
	const onsave = (entry: ConfigEntry, value: ConfigValue) => ask([{ entry, value, reset: false }]);
	const onreset = (entry: ConfigEntry) => ask([{ entry, value: entry.default, reset: true }]);

	/** Anzeige in der Einheit der Oberflaeche (Schwellen in Prozent). */
	function show(c: Change, v: ConfigValue): string {
		const rule = RULES.find((r) => c.entry.key.startsWith(`DASH_WARN_${r.rule}_`));
		if (rule && typeof v === 'number') return `${toInput(rule.unit, v)} ${unitSuffix(rule.unit)}`;
		return formatValue(c.entry, v);
	}
	const needsRestart = $derived(pending.some((c) => c.entry.apply === 'restart'));

	function replace(updated: ConfigEntry): void {
		if (!res.data) return;
		res.data.entries = res.data.entries.map((e) => (e.key === updated.key ? updated : e));
	}

	async function confirm(): Promise<void> {
		busy = true;
		dialogError = null;
		const done: string[] = [];
		try {
			for (const c of pending) {
				const updated = c.reset
					? await api.resetConfig(c.entry.key)
					: await api.setConfig(c.entry.key, c.value);
				replace(updated);
				done.push(c.entry.key);
			}
			confirmOpen = false;
			toast.success(
				done.length > 1 ? `${done.length} Einstellungen gespeichert` : `${done[0]} gespeichert`,
				needsRestart ? 'Wirkt erst nach einem Neustart.' : 'Wirkt nach höchstens 30 Sekunden.'
			);
			await reloadRestart();
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') {
				session.expire();
				return;
			}
			dialogError =
				(done.length ? `Gespeichert: ${done.join(', ')}. ` : '') +
				(e instanceof ApiError && e.serverCode === 'validation'
					? 'Der Server hat den Wert abgelehnt (Typ oder Grenzen). Bitte Eingabe prüfen.'
					: describeError(e));
			// Stand neu laden, damit die Zeilen den echten Zustand zeigen.
			void res.load();
		} finally {
			busy = false;
		}
	}

	// ------------------------------------------------------------ Neustart

	let restartOpen = $state(false);
	let restartBusy = $state(false);
	let restartError = $state<string | null>(null);
	let poll: ReturnType<typeof setInterval> | undefined;

	async function reloadRestart(): Promise<void> {
		try {
			const r = await api.restartState();
			if (res.data) res.data.restart = r;
			if (rolling && !poll) poll = setInterval(pollRestart, 3000);
		} catch {
			/* Anzeige bleibt auf dem letzten Stand. */
		}
	}
	async function pollRestart(): Promise<void> {
		await reloadRestart();
		if (!rolling) {
			clearInterval(poll);
			poll = undefined;
			void res.load();
		}
	}
	onMount(() => () => clearInterval(poll));

	const restart = $derived(res.data?.restart);
	const pendingKeys = $derived(restart?.pending ?? []);
	const rolling = $derived(
		!!restart && restart.replicas.some((r) => r.appliedGeneration < restart.generation)
	);

	async function doRestart(): Promise<void> {
		restartBusy = true;
		restartError = null;
		try {
			await api.requestRestart();
			restartOpen = false;
			toast.success('Neustart ausgelöst', 'Die Replikate starten nacheinander neu.');
			await reloadRestart();
			if (!poll) poll = setInterval(pollRestart, 3000);
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
			else restartError = describeError(e);
		} finally {
			restartBusy = false;
		}
	}

	// ------------------------------------------------------------ Push-Pause

	let pauseOpen = $state(false);
	let pauseBusy = $state(false);
	let wantPause = $state(true);
	async function applyPause(): Promise<void> {
		pauseBusy = true;
		try {
			await insights.setPaused(wantPause);
			toast.success(wantPause ? 'Versand pausiert' : 'Versand fortgesetzt');
			pauseOpen = false;
			void pause.load();
		} catch (e) {
			toast.error('Aktion fehlgeschlagen', describeError(e));
			pauseOpen = false;
		} finally {
			pauseBusy = false;
		}
	}

	// ------------------------------------------------------------ Darstellung

	const stateLabel: Record<string, string> = { current: 'aktuell', waiting: 'wartet auf Neustart' };
	const groups = (entries: ConfigEntry[]) =>
		groupEntries(entries, { query, onlyChanged }).filter((g) => g.name !== THRESHOLD_GROUP);
	const thresholds = (entries: ConfigEntry[]) => {
		const visible = groupEntries(entries, { query, onlyChanged }).find(
			(g) => g.name === THRESHOLD_GROUP
		);
		return visible ? thresholdRows(visible.entries) : { rows: [], rest: [] };
	};
</script>

<PageHeader
	title="Konfiguration"
	description="Rangfolge: Umgebungsvariable vor Dashboard-Wert vor Standard. Geheimnisse und reine Umgebungswerte werden nie angezeigt."
>
	{#snippet actions()}
		<Button
			variant="outline"
			onclick={() => ((restartError = null), (restartOpen = true))}
			disabled={rolling}
		>
			<RotateCwIcon aria-hidden="true" />Dienst neu starten
		</Button>
	{/snippet}
</PageHeader>

<Loadable {res}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		{#if pendingKeys.length > 0 || rolling}
			<div
				class="bg-warn-soft text-warn flex items-start gap-3 rounded-xl border border-transparent px-4 py-3 text-sm"
				role="status"
			>
				<RotateCwIcon
					class="mt-0.5 size-4 shrink-0 {rolling ? 'motion-safe:animate-spin' : ''}"
					aria-hidden="true"
				/>
				<div class="min-w-0">
					<p class="font-medium">{rolling ? 'Neustart läuft' : 'Neustart nötig'}</p>
					{#if rolling}
						<ul class="mt-1 space-y-0.5">
							{#each o.restart.replicas as r (r.id)}
								<li>
									Replikat <span class="font-mono">{r.id}</span>:
									{r.appliedGeneration >= o.restart.generation
										? 'neu gestartet'
										: (stateLabel[r.state] ?? r.state)}
								</li>
							{/each}
						</ul>
					{:else}
						<p>
							Diese Einstellungen wirken erst nach einem Neustart:
							<span class="font-mono">{pendingKeys.join(', ')}</span>.
						</p>
					{/if}
				</div>
			</div>
		{/if}

		<Panel
			title="Push-Versand"
			description="Pause: Die Auswertung läuft weiter, es wird nichts gesendet. Die Warteschlange läuft nach 6 Stunden ab."
		>
			{#snippet actions()}
				{#if pause.data?.pushEnabled}
					<Button
						variant="outline"
						size="sm"
						onclick={() => ((wantPause = !pause.data!.pushPaused), (pauseOpen = true))}
					>
						{#if pause.data.pushPaused}<PlayIcon aria-hidden="true" />Versand fortsetzen{:else}<PauseIcon
								aria-hidden="true"
							/>Versand pausieren{/if}
					</Button>
				{/if}
			{/snippet}
			{#if pause.data === null}
				<p class="text-muted-foreground text-sm" role="status">
					{pause.error ?? 'Lade …'}
				</p>
			{:else if !pause.data.pushEnabled}
				<p class="flex items-center gap-2 text-sm">
					<BellOffIcon class="text-muted-foreground size-4" aria-hidden="true" />
					Push ist ausgeschaltet (<span class="font-mono">PUSH_ENABLED</span>). Es gibt nichts zu
					pausieren.
				</p>
			{:else}
				<p class="flex flex-wrap items-center gap-2 text-sm">
					<StatusBadge
						tone={pause.data.pushPaused ? 'warn' : 'ok'}
						label={pause.data.pushPaused ? 'Pausiert' : 'Aktiv'}
					/>
					{pause.data.pushPaused
						? 'Es wird derzeit nichts gesendet.'
						: 'Mitteilungen werden normal gesendet.'}
				</p>
			{/if}
		</Panel>

		<div class="flex flex-wrap items-center gap-x-5 gap-y-3">
			<div class="relative w-full max-w-sm">
				<SearchIcon
					class="text-muted-foreground pointer-events-none absolute top-2 left-2.5 size-4"
					aria-hidden="true"
				/>
				<Input
					bind:value={query}
					type="search"
					placeholder="Schlüssel oder Beschreibung suchen"
					aria-label="Einstellungen durchsuchen"
					class="pl-8"
				/>
			</div>
			<label class="flex items-center gap-2 text-sm">
				<input type="checkbox" bind:checked={onlyChanged} class="accent-primary size-4" />
				Nur Dashboard-Werte
			</label>
			<a
				href={resolve('/protokoll')}
				class="text-primary-ink ml-auto text-sm underline-offset-4 hover:underline"
				>Änderungen im Protokoll</a
			>
		</div>

		{@const thr = thresholds(o.entries)}
		{#if thr.rows.length || thr.rest.length}
			<Panel
				title="Schwellen für Befunde"
				description="Ab diesen Werten zeigt das Dashboard Warnungen (gelb) und kritische Befunde (rot). Wirkt nach höchstens 30 Sekunden. Die Startwerte sind Vorschläge und werden nach zwei Wochen Betrieb kalibriert."
			>
				{#each thr.rows as row (row.def.rule)}
					<ThresholdRule
						{row}
						onsave={(changes) => ask(changes.map((c) => ({ ...c, reset: false })))}
						onreset={(entries) =>
							ask(entries.map((entry) => ({ entry, value: entry.default, reset: true })))}
					/>
				{/each}
				{#each thr.rest as entry (entry.key)}
					<ConfigRow {entry} {onsave} {onreset} />
				{/each}
			</Panel>
		{/if}

		{#each groups(o.entries) as g (g.name)}
			<Panel title={g.name}>
				{#each g.entries as entry (entry.key)}
					<ConfigRow {entry} {onsave} {onreset} />
				{/each}
			</Panel>
		{:else}
			{#if !thr.rows.length && !thr.rest.length}
				<p class="text-muted-foreground py-6 text-center text-sm" role="status">
					Keine Einstellung passt zur Suche.
				</p>
			{/if}
		{/each}
		<p class="text-muted-foreground text-xs">Register-Revision {o.revision}.</p>
	{/snippet}
</Loadable>

<ConfirmDialog
	bind:open={confirmOpen}
	title={pending[0]?.reset ? 'Auf Standard zurücksetzen?' : 'Änderung speichern?'}
	description={needsRestart
		? 'Mindestens eine Einstellung wirkt erst nach einem Neustart des Dienstes.'
		: 'Die Änderung wirkt auf allen Replikaten nach höchstens 30 Sekunden.'}
	confirmLabel={pending[0]?.reset ? 'Zurücksetzen' : 'Speichern'}
	{busy}
	onconfirm={confirm}
>
	<ul class="space-y-2 text-sm">
		{#each pending as c (c.entry.key)}
			<li class="bg-muted/60 rounded-lg px-3 py-2">
				<p class="font-mono text-[13px] font-semibold break-all">{c.entry.key}</p>
				<p class="num">
					<span class="text-muted-foreground">{show(c, c.entry.value)}</span>
					<span aria-hidden="true"> → </span><span class="sr-only"> wird zu </span>
					<span class="font-medium">{show(c, c.value)}</span>
				</p>
				<p class="text-muted-foreground text-xs">{applyLabel[c.entry.apply]}</p>
			</li>
		{/each}
	</ul>
	{#if dialogError}<p role="alert" class="text-destructive text-sm">{dialogError}</p>{/if}
</ConfirmDialog>

<ConfirmDialog
	bind:open={restartOpen}
	title="Dienst neu starten?"
	description={(restart?.replicas.length ?? 0) < 2
		? 'Es läuft nur ein Replikat: Der Dienst ist kurz nicht erreichbar.'
		: `${restart?.replicas.length} Replikate starten nacheinander neu; der Dienst bleibt erreichbar.`}
	confirmLabel="Jetzt neu starten"
	destructive
	busy={restartBusy}
	onconfirm={doRestart}
>
	{#if pendingKeys.length}
		<p class="text-sm">Übernommen werden:</p>
		<ul class="font-mono text-[13px]">
			{#each pendingKeys as key (key)}<li>{key}</li>{/each}
		</ul>
	{:else}
		<p class="text-muted-foreground text-sm">
			Es sind keine Einstellungen zur Übernahme vorgemerkt.
		</p>
	{/if}
	{#if restartError}<p role="alert" class="text-destructive text-sm">{restartError}</p>{/if}
</ConfirmDialog>

<ConfirmDialog
	bind:open={pauseOpen}
	title={wantPause ? 'Versand pausieren?' : 'Versand fortsetzen?'}
	description={wantPause
		? 'Die Auswertung läuft weiter, es wird nichts mehr gesendet. Wartende Einträge laufen nach 6 Stunden ab.'
		: 'Der Versand läuft wieder an. Noch nicht abgelaufene Einträge der Warteschlange werden gesendet.'}
	confirmLabel={wantPause ? 'Pausieren' : 'Fortsetzen'}
	busy={pauseBusy}
	onconfirm={applyPause}
/>
