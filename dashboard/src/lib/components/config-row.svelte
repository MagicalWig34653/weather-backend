<script lang="ts">
	import { untrack } from 'svelte';
	import { api } from '#lib/client.js';
	import { ApiError, type ConfigEntry } from '#lib/api.js';
	import { session } from '#lib/session.svelte.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';
	import LockIcon from '@lucide/svelte/icons/lock';

	let { entry, onchange }: { entry: ConfigEntry; onchange: (e: ConfigEntry) => void } = $props();

	// Entwurf startet bewusst mit dem aktuellen Wert; spaetere Aenderungen setzt run() selbst.
	const initial = () => (entry.value === null ? '' : String(entry.value));
	let draft = $state(initial());
	let checked = $state(untrack(() => entry.value === true));
	let error = $state<string | null>(null);
	let busy = $state(false);

	const isBool = $derived(entry.type === 'bool');
	const dirty = $derived(
		isBool
			? checked !== (entry.value === true)
			: draft !== (entry.value === null ? '' : String(entry.value))
	);
	const canReset = $derived(entry.source === 'dashboard');
	const id = $derived(`cfg-${entry.key}`);
	const bounds = $derived(
		entry.min !== null && entry.max !== null
			? `${entry.min} bis ${entry.max}${entry.unit ? ' ' + entry.unit : ''}`
			: entry.unit
	);

	function parse(): string | number | boolean {
		if (isBool) return checked;
		if (entry.type === 'int' || entry.type === 'double' || entry.type === 'duration') {
			return Number(draft.replace(',', '.'));
		}
		return draft;
	}

	async function run(action: () => Promise<ConfigEntry>): Promise<void> {
		busy = true;
		error = null;
		try {
			const updated = await action();
			onchange(updated);
			draft = updated.value === null ? '' : String(updated.value);
			checked = updated.value === true;
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
			else if (e instanceof ApiError && e.code === 'rate_limited')
				error = 'Zu viele Änderungen. Bitte kurz warten.';
			else error = e instanceof ApiError ? e.message : 'Unbekannter Fehler.';
		} finally {
			busy = false;
		}
	}
</script>

<div class="grid gap-3 py-4 sm:grid-cols-[1fr_minmax(0,18rem)] sm:gap-6">
	<div class="space-y-1.5">
		<div class="flex flex-wrap items-center gap-2">
			<Label for={id} class="font-mono text-sm">{entry.key}</Label>
			{#if entry.locked}
				<Badge variant="outline"
					><LockIcon aria-hidden="true" class="size-3" />Durch Umgebungsvariable festgelegt</Badge
				>
			{:else if entry.source === 'dashboard'}
				<Badge variant="secondary">Dashboard-Wert</Badge>
			{:else}
				<Badge variant="outline">Standard</Badge>
			{/if}
			<Badge variant={entry.apply === 'restart' ? 'outline' : 'secondary'}>
				{entry.apply === 'restart' ? 'Neustart nötig' : 'wirkt sofort'}
			</Badge>
			{#if entry.restart_pending}
				<Badge class="bg-warning text-warning-foreground">Neustart ausstehend</Badge>
			{/if}
		</div>
		<p class="text-muted-foreground text-sm" id="{id}-desc">{entry.description}</p>
		<p class="text-muted-foreground text-xs">
			Typ {entry.type}{bounds ? `, erlaubt ${bounds}` : ''}{entry.default !== null
				? `, Standard ${entry.default}`
				: ''}
		</p>
	</div>

	<form
		class="space-y-2"
		onsubmit={(ev) => {
			ev.preventDefault();
			void run(() => api.setConfig(entry.key, parse()));
		}}
	>
		{#if entry.secret}
			<Input
				{id}
				value=""
				placeholder="Geheimnis, nur per Umgebungsvariable"
				disabled
				aria-describedby="{id}-desc"
			/>
		{:else if isBool}
			<label class="flex items-center gap-2 text-sm">
				<input
					{id}
					type="checkbox"
					bind:checked
					disabled={entry.locked || busy}
					class="accent-primary size-4"
					aria-describedby="{id}-desc"
				/>
				{checked ? 'Ein' : 'Aus'}
			</label>
		{:else}
			<Input
				{id}
				bind:value={draft}
				disabled={entry.locked || busy}
				inputmode={entry.type === 'int' ? 'numeric' : undefined}
				aria-invalid={error ? true : undefined}
				aria-describedby="{id}-desc{error ? ` ${id}-err` : ''}"
			/>
		{/if}
		{#if error}
			<p id="{id}-err" role="alert" class="text-destructive text-sm">{error}</p>
		{/if}
		{#if !entry.locked}
			<div class="flex gap-2">
				<Button type="submit" size="sm" disabled={!dirty || busy}>Speichern</Button>
				<Button
					type="button"
					size="sm"
					variant="outline"
					disabled={!canReset || busy}
					onclick={() => run(() => api.resetConfig(entry.key))}
				>
					Auf Standard
				</Button>
			</div>
		{/if}
	</form>
</div>
