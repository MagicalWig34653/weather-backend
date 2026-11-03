<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/client.js';
	import { ApiError, type ConfigEntry, type RestartState } from '#lib/api.js';
	import { Resource } from '#lib/resource.svelte.js';
	import { session } from '#lib/session.svelte.js';
	import ConfigRow from '#lib/components/config-row.svelte';
	import * as Alert from '#lib/components/ui/alert/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import * as Dialog from '#lib/components/ui/dialog/index.js';
	import { Separator } from '#lib/components/ui/separator/index.js';
	import RotateCwIcon from '@lucide/svelte/icons/rotate-cw';

	let entries = $state<ConfigEntry[]>([]);
	let restart = $state<RestartState | null>(null);
	const config = new Resource(async () => {
		const [c, r] = await Promise.all([api.config(), api.restartState()]);
		entries = c.entries;
		restart = r;
		return c;
	});

	let dialogOpen = $state(false);
	let restarting = $state(false);
	let restartError = $state<string | null>(null);
	let poll: ReturnType<typeof setInterval> | undefined;

	onMount(() => {
		void config.load();
		return () => clearInterval(poll);
	});

	const groups = $derived.by(() => {
		const result: [string, ConfigEntry[]][] = [];
		for (const e of entries) {
			const found = result.find(([g]) => g === e.group);
			if (found) found[1].push(e);
			else result.push([e.group, [e]]);
		}
		return result;
	});

	const pending = $derived(restart?.pending_keys ?? []);
	const rolling = $derived(
		!!restart && restart.replicas.some((r) => r.applied_generation < restart!.generation)
	);
	const singleReplica = $derived((restart?.replicas.length ?? 0) < 2);

	function changed(updated: ConfigEntry): void {
		entries = entries.map((e) => (e.key === updated.key ? updated : e));
		void api
			.restartState()
			.then((r) => (restart = r))
			.catch(() => {});
	}

	async function confirmRestart(): Promise<void> {
		restarting = true;
		restartError = null;
		try {
			restart = await api.requestRestart();
			dialogOpen = false;
			entries = entries.map((e) => ({ ...e, restart_pending: false }));
			clearInterval(poll);
			poll = setInterval(async () => {
				try {
					restart = await api.restartState();
					if (!restart.replicas.some((r) => r.applied_generation < restart!.generation))
						clearInterval(poll);
				} catch {
					/* Replikat startet gerade neu: weiter versuchen. */
				}
			}, 3000);
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
			else if (e instanceof ApiError && e.code === 'rate_limited')
				restartError = 'Der letzte Neustart ist zu kurz her. Bitte einige Minuten warten.';
			else restartError = e instanceof ApiError ? e.message : 'Unbekannter Fehler.';
		} finally {
			restarting = false;
		}
	}

	const stateLabel = { running: 'läuft', waiting: 'wartet', restarting: 'startet neu' } as const;
</script>

<div class="space-y-1">
	<h1 class="text-2xl font-semibold tracking-tight">Konfiguration</h1>
	<p class="text-muted-foreground text-sm">
		Rangfolge: Umgebungsvariable vor Dashboard-Wert vor Standard. Geheimnisse sind nur per
		Umgebungsvariable setzbar und werden nie angezeigt.
	</p>
</div>

{#if config.error}
	<Alert.Root variant="destructive"
		><Alert.Description>{config.error}</Alert.Description></Alert.Root
	>
{:else if !config.data}
	<p class="text-muted-foreground" role="status">Lade …</p>
{:else}
	{#if pending.length > 0 || rolling}
		<Alert.Root class="border-warning-foreground/30 bg-warning text-warning-foreground">
			<RotateCwIcon aria-hidden="true" />
			<Alert.Title>{rolling ? 'Neustart läuft' : 'Neustart nötig'}</Alert.Title>
			<Alert.Description class="text-warning-foreground/90">
				{#if rolling && restart}
					<ul class="mt-1 space-y-0.5">
						{#each restart.replicas as r (r.slot)}
							<li>
								Replikat {r.slot}: {r.applied_generation >= restart.generation
									? 'neu gestartet'
									: stateLabel[r.state]}
							</li>
						{/each}
					</ul>
				{:else}
					Folgende Einstellungen wirken erst nach einem Neustart:
					<span class="font-mono">{pending.join(', ')}</span>.
					<div class="mt-3">
						<Button size="sm" onclick={() => ((restartError = null), (dialogOpen = true))}
							>Radar-Dienst neu starten</Button
						>
					</div>
				{/if}
			</Alert.Description>
		</Alert.Root>
	{/if}

	{#each groups as [group, items] (group)}
		<Card.Root>
			<Card.Header><Card.Title>{group}</Card.Title></Card.Header>
			<Card.Content>
				{#each items as entry, i (entry.key)}
					{#if i > 0}<Separator />{/if}
					<ConfigRow {entry} onchange={changed} />
				{/each}
			</Card.Content>
		</Card.Root>
	{/each}
{/if}

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>Radar-Dienst neu starten?</Dialog.Title>
			<Dialog.Description>
				Die Replikate starten nacheinander neu und übernehmen dabei diese Einstellungen:
			</Dialog.Description>
		</Dialog.Header>
		<ul class="font-mono text-sm">
			{#each pending as key (key)}<li>{key}</li>{/each}
		</ul>
		{#if singleReplica}
			<p class="text-sm">Es läuft nur ein Replikat: Der Dienst ist kurz nicht erreichbar.</p>
		{/if}
		{#if restartError}
			<p role="alert" class="text-destructive text-sm">{restartError}</p>
		{/if}
		<Dialog.Footer>
			<Button variant="outline" onclick={() => (dialogOpen = false)}>Abbrechen</Button>
			<Button onclick={confirmRestart} disabled={restarting}
				>{restarting ? 'Wird ausgelöst …' : 'Jetzt neu starten'}</Button
			>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
