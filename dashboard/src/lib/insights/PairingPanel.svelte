<script lang="ts">
	import { tick, untrack } from 'svelte';
	import KeyRoundIcon from '@lucide/svelte/icons/key-round';
	import LockIcon from '@lucide/svelte/icons/lock';
	import { ApiError } from '#lib/api.js';
	import { session } from '#lib/session.svelte.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import Panel from '#lib/design/Panel.svelte';
	import Segmented from '#lib/design/Segmented.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { describePairingError, insights } from './api.js';
	import {
		PAIRING_POLL_MS,
		defaultChoice,
		formatCountdown,
		pairingChoices,
		pairingPhase
	} from './pairing.js';
	import type { PairingState, PairingWindow } from './types.js';

	let {
		pairing,
		onrefresh
	}: {
		/** Zustand laut letzter Geraeteliste. */
		pairing: PairingWindow;
		/** Laedt die Geraeteliste neu (Abfrage waehrend das Fenster offen ist). */
		onrefresh: () => void;
	} = $props();

	let local = $state<PairingState>({ open: false, endsAt: null });
	let nowMs = $state(Date.now());
	let minutes = $state(
		defaultChoice(
			untrack(() => pairing.defaultMinutes),
			untrack(() => pairing.maxMinutes)
		)
	);
	let busy = $state(false);
	let error = $state<string | null>(null);
	/** Letztes Ereignis, nachdem das Fenster zuging (bleibt sichtbar bis zum naechsten Oeffnen). */
	let notice = $state<string | null>(null);
	let announce = $state('');
	let actedAt = 0;
	let wasEnding = false;

	const choices = $derived(pairingChoices(pairing.maxMinutes));
	const view = $derived(pairingPhase(local, nowMs));
	const isOpen = $derived(view.phase === 'open' || view.phase === 'ending');
	const until = $derived(
		local.endsAt
			? new Intl.DateTimeFormat('de-DE', { hour: '2-digit', minute: '2-digit' }).format(
					new Date(local.endsAt)
				)
			: ''
	);

	// Serverzustand uebernehmen; erkennt Schliessen von aussen (Kopplung eingeloest, anderer Tab).
	$effect(() => {
		const next: PairingState = { open: pairing.open, endsAt: pairing.endsAt };
		untrack(() => {
			if (Date.now() - actedAt < 1500) return; // Antwort koennte aelter als die eigene Aktion sein
			if (local.open && !next.open) {
				const early = pairingPhase(local, Date.now()).remaining > 2;
				notice = early
					? 'Das Kopplungsfenster wurde geschlossen (Kopplung eingelöst oder an anderer Stelle beendet).'
					: 'Das Kopplungsfenster ist abgelaufen.';
				announce = notice;
			}
			if (!local.open && next.open) notice = null;
			local = next;
		});
	});

	// Uhr und Abfrage nur, solange das Fenster offen ist.
	$effect(() => {
		if (!local.open) return;
		nowMs = Date.now();
		const clock = setInterval(() => (nowMs = Date.now()), 1000);
		const poll = setInterval(onrefresh, PAIRING_POLL_MS);
		return () => {
			clearInterval(clock);
			clearInterval(poll);
		};
	});

	// Ablauf ohne Neuladen: Frist verstrichen, Server noch nicht abgefragt.
	$effect(() => {
		if (view.phase === 'expired') {
			untrack(() => {
				local = { open: false, endsAt: null };
				notice = 'Das Kopplungsfenster ist abgelaufen.';
				announce = notice;
				onrefresh();
			});
		}
	});
	$effect(() => {
		const ending = view.phase === 'ending';
		if (ending && !wasEnding) announce = 'Das Kopplungsfenster läuft in 30 Sekunden ab.';
		wasEnding = ending;
	});

	let openBtn: HTMLButtonElement | null = $state(null);
	let closeBtn: HTMLButtonElement | null = $state(null);

	async function fail(e: unknown): Promise<void> {
		if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
		error = describePairingError(e);
		toast.error('Kopplungsfenster', error);
	}

	async function open(): Promise<void> {
		busy = true;
		error = null;
		try {
			actedAt = Date.now();
			local = await insights.openPairing(minutes);
			nowMs = Date.now();
			notice = null;
			announce = `Kopplungsfenster geöffnet bis ${until} Uhr.`;
			toast.success('Kopplung freigegeben', `Offen bis ${until} Uhr.`);
			onrefresh();
			busy = false;
			await tick();
			closeBtn?.focus();
		} catch (e) {
			await fail(e);
		} finally {
			busy = false;
		}
	}
	async function close(): Promise<void> {
		busy = true;
		error = null;
		try {
			actedAt = Date.now();
			local = await insights.closePairing();
			notice = 'Das Kopplungsfenster wurde geschlossen.';
			announce = notice;
			toast.success('Kopplungsfenster geschlossen');
			onrefresh();
			busy = false;
			await tick();
			openBtn?.focus();
		} catch (e) {
			await fail(e);
		} finally {
			busy = false;
		}
	}
</script>

<Panel
	title="Kopplung freigeben"
	description="Nur bei offenem Fenster zeigt die App einen Koppelcode an."
	class={isOpen ? 'border-primary/50' : ''}
>
	<div class="flex flex-wrap items-center gap-x-4 gap-y-2">
		{#if view.phase === 'ending'}
			<StatusBadge tone="warn" label="Läuft ab" />
		{:else if isOpen}
			<StatusBadge tone="ok" label="Offen" />
		{:else}
			<StatusBadge tone="neutral" label="Geschlossen" />
		{/if}
		{#if isOpen}
			<span class="text-[13px]">
				offen bis <strong class="num font-semibold">{until} Uhr</strong>, noch
				<span class="sr-only">{Math.ceil(view.remaining / 60)} Minuten</span>
				<strong class="num text-lg font-semibold tabular-nums" aria-hidden="true"
					>{formatCountdown(view.remaining)}</strong
				>
			</span>
		{:else if notice}
			<span class="text-muted-foreground text-[13px]">{notice}</span>
		{/if}
	</div>

	<div class="mt-4 flex flex-wrap items-end gap-3">
		{#if isOpen}
			<Button variant="outline" disabled={busy} onclick={close} bind:ref={closeBtn}>
				<LockIcon aria-hidden="true" />Jetzt schließen
			</Button>
		{:else}
			<div class="space-y-1.5">
				<span class="text-[13px] font-medium">Dauer</span>
				<Segmented
					label="Dauer des Kopplungsfensters"
					size="sm"
					options={choices.map((m) => ({
						value: String(m),
						label: `${m} Min.`,
						title: `${m} ${m === 1 ? 'Minute' : 'Minuten'}`
					}))}
					value={String(minutes)}
					onchange={(v) => (minutes = Number(v))}
				/>
			</div>
			<Button disabled={busy} onclick={open} bind:ref={openBtn}>
				<KeyRoundIcon aria-hidden="true" />Kopplung freigeben ({minutes} Min.)
			</Button>
		{/if}
	</div>
	{#if error}<p role="alert" class="text-destructive mt-2 text-[13px]">{error}</p>{/if}

	<ol class="text-muted-foreground mt-4 list-decimal space-y-1 pl-5 text-[13px] leading-5">
		<li>Freigeben.</li>
		<li>
			In der App das Info-Sheet öffnen (ganz unten: Betreiber-Diagnose) und den Schalter
			einschalten.
		</li>
		<li>Angezeigten Code unten eintragen.</li>
	</ol>
	<p class="text-muted-foreground mt-3 text-[13px] leading-5">
		Solange das Fenster offen ist, kann jede Person mit der App einen Code anzeigen, einlösen kannst
		ihn aber nur du hier. Nach der ersten Kopplung schließt sich das Fenster automatisch. Ein
		angezeigter Code bleibt bis zu 10 Minuten einlösbar.
	</p>
	<p class="sr-only" role="status" aria-live="polite">{announce}</p>
</Panel>
