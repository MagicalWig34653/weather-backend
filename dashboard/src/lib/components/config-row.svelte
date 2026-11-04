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
	const initial = () => entry.value ?? '';
	let draft = $state(initial());
	let checked = $state(untrack(() => entry.value === 'true'));
	let error = $state<string | null>(null);
	let busy = $state(false);

	const isBool = $derived(entry.type === 'bool');
	const dirty = $derived(
		isBool ? checked !== (entry.value === 'true') : draft !== (entry.value ?? '')
	);
	const canReset = $derived(entry.source === 'dashboard');
	const id = $derived(`cfg-${entry.key}`);
	const bounds = $derived(
		entry.minimum != null && entry.maximum != null
			? `${entry.minimum} bis ${entry.maximum}${entry.unit ? ' ' + entry.unit : ''}`
			: entry.maxLength != null
				? `bis ${entry.maxLength} Zeichen`
				: entry.choices?.length
					? entry.choices.join(', ')
					: entry.unit
	);

	// Das Backend erwartet immer Text und prueft Typ und Grenzen selbst (422 mit Begruendung).
	function parse(): string {
		return isBool ? String(checked) : draft.trim();
	}

	const readonly = $derived(entry.lockedByEnv || !entry.editable);

	async function run(action: () => Promise<ConfigEntry>): Promise<void> {
		busy = true;
		error = null;
		try {
			const updated = await action();
			onchange(updated);
			draft = updated.value ?? '';
			checked = updated.value === 'true';
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') session.expire();
			else if (e instanceof ApiError && e.code === 'rate_limited')
				error = 'Zu viele Änderungen. Bitte kurz warten.';
			else if (e instanceof ApiError && e.code === 'conflict')
				error = 'Durch Umgebungsvariable festgelegt, nicht änderbar.';
			else if (e instanceof ApiError && e.code === 'forbidden')
				error = 'Dieser Wert ist nicht über das Dashboard änderbar.';
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
			{#if entry.lockedByEnv}
				<Badge variant="outline"
					><LockIcon aria-hidden="true" class="size-3" />Durch Umgebungsvariable festgelegt</Badge
				>
			{:else if !entry.editable && !entry.secret}
				<Badge variant="outline"
					><LockIcon aria-hidden="true" class="size-3" />Nur per Umgebungsvariable</Badge
				>
			{:else if entry.source === 'dashboard'}
				<Badge variant="secondary">Dashboard-Wert</Badge>
			{:else}
				<Badge variant="outline">Standard</Badge>
			{/if}
			<Badge variant={entry.apply === 'live' ? 'secondary' : 'outline'}>
				{entry.apply === 'restart'
					? 'Neustart nötig'
					: entry.apply === 'live'
						? 'wirkt sofort'
						: 'Bootstrap-Wert'}
			</Badge>
			{#if entry.restartPending}
				<Badge class="bg-warning text-warning-foreground">Neustart ausstehend</Badge>
			{/if}
		</div>
		<p class="text-muted-foreground text-sm" id="{id}-desc">{entry.summary}</p>
		<p class="text-muted-foreground text-xs">
			Typ {entry.type}{bounds ? `, erlaubt ${bounds}` : ''}{entry.defaultValue != null
				? `, Standard ${entry.defaultValue}`
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
					disabled={readonly || busy}
					class="accent-primary size-4"
					aria-describedby="{id}-desc"
				/>
				{checked ? 'Ein' : 'Aus'}
			</label>
		{:else if entry.type === 'choice' && entry.choices}
			<select
				{id}
				bind:value={draft}
				disabled={readonly || busy}
				aria-describedby="{id}-desc"
				class="border-input bg-background focus-visible:ring-ring/50 h-9 w-full rounded-lg border px-2 text-sm outline-none focus-visible:ring-3 disabled:opacity-50"
			>
				{#each entry.choices as c (c)}<option value={c}>{c}</option>{/each}
			</select>
		{:else}
			<Input
				{id}
				bind:value={draft}
				disabled={readonly || busy}
				inputmode={entry.type === 'int' ? 'numeric' : undefined}
				aria-invalid={error ? true : undefined}
				aria-describedby="{id}-desc{error ? ` ${id}-err` : ''}"
			/>
		{/if}
		{#if error}
			<p id="{id}-err" role="alert" class="text-destructive text-sm">{error}</p>
		{/if}
		{#if !readonly}
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
