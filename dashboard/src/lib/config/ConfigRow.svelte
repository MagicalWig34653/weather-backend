<script lang="ts">
	import { untrack } from 'svelte';
	import LockIcon from '@lucide/svelte/icons/lock';
	import RotateCcwIcon from '@lucide/svelte/icons/rotate-ccw';
	import type { ConfigEntry, ConfigValue } from '#lib/api.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import {
		applyLabel,
		boundsText,
		canReset,
		draftOf,
		formatValue,
		isBool,
		isDirty,
		isHidden,
		isNumeric,
		parseDraft,
		sourceLabel,
		typeLabel
	} from './form.js';

	let {
		entry,
		onsave,
		onreset
	}: {
		entry: ConfigEntry;
		/** Fragt die Aenderung an; die Seite zeigt die Bestaetigung. */
		onsave: (entry: ConfigEntry, value: ConfigValue) => void;
		onreset: (entry: ConfigEntry) => void;
	} = $props();

	let draft = $state<string | boolean>(untrack(() => draftOf(entry)));
	let touched = $state(false);
	// Der Server ist die Quelle: Ein geaenderter Wert (Speichern, Zuruecksetzen) ersetzt den Entwurf;
	// ein Nachladen mit gleichem Wert laesst eine laufende Eingabe unberuehrt.
	let seen = untrack(() => JSON.stringify(entry.value));
	$effect(() => {
		const now = JSON.stringify(entry.value);
		if (now === seen) return;
		seen = now;
		draft = draftOf(entry);
		touched = false;
	});

	const id = $derived(`cfg-${entry.key}`);
	const parsed = $derived(parseDraft(entry, draft));
	const dirty = $derived(isDirty(entry, draft));
	const error = $derived(touched && !parsed.ok ? parsed.error : null);
	const bounds = $derived(boundsText(entry));
	const hidden = $derived(isHidden(entry));

	function submit(ev: Event): void {
		ev.preventDefault();
		touched = true;
		if (parsed.ok && dirty) onsave(entry, parsed.value);
	}
</script>

<div
	class="grid gap-3 py-4 first:pt-0 last:pb-0 md:grid-cols-[minmax(0,1fr)_minmax(0,20rem)] md:gap-8"
>
	<div class="min-w-0 space-y-1.5">
		<div class="flex flex-wrap items-center gap-x-2 gap-y-1.5">
			<Label for={id} class="font-mono text-[13px] font-semibold break-all">{entry.key}</Label>
			{#if entry.locked}
				<StatusBadge tone="neutral" icon={false}>
					<LockIcon class="size-3" aria-hidden="true" />Umgebungsvariable
				</StatusBadge>
			{:else if entry.source === 'dashboard'}
				<StatusBadge tone="info" icon={false} label="Dashboard-Wert" />
			{:else}
				<StatusBadge tone="neutral" icon={false} label="Standard" />
			{/if}
			<StatusBadge
				tone={entry.apply === 'restart' ? 'warn' : 'neutral'}
				icon={false}
				label={entry.apply === 'restart' ? 'Neustart nötig' : 'wirkt sofort'}
			/>
			{#if entry.restartPending}<StatusBadge tone="warn" label="Neustart ausstehend" />{/if}
		</div>
		<p class="text-muted-foreground text-[13px] leading-5" id="{id}-desc">{entry.description}</p>
		<p class="text-muted-foreground text-xs">
			{typeLabel[entry.type] ?? entry.type}{bounds ? `, erlaubt ${bounds}` : ''}{entry.default !==
				null && entry.default !== ''
				? `, Standard ${formatValue(entry, entry.default)}`
				: ''}. {applyLabel[entry.apply][0].toUpperCase()}{applyLabel[entry.apply].slice(1)}. Quelle:
			{sourceLabel[entry.source]}.
		</p>
	</div>

	<form class="min-w-0 space-y-2" onsubmit={submit} novalidate>
		{#if entry.locked}
			<!-- Gesperrt: Wert nur lesen. Geheimnisse und ENV-only-Werte liefert der Server nie (value null). -->
			<Input
				{id}
				value={hidden ? '' : formatValue(entry)}
				placeholder={hidden ? 'verborgen (Geheimnis oder nur per Umgebung)' : undefined}
				readonly
				aria-readonly="true"
				aria-describedby="{id}-desc"
				class="bg-muted/50 font-mono"
			/>
			<p class="text-muted-foreground text-xs">
				Wird per Umgebungsvariable festgelegt und lässt sich hier nicht ändern.
			</p>
		{:else}
			{#if isBool(entry)}
				<label class="flex min-h-8 items-center gap-2.5 text-sm">
					<input
						{id}
						type="checkbox"
						bind:checked={draft as boolean}
						class="accent-primary size-4"
						aria-describedby="{id}-desc"
					/>
					{draft ? 'Ein' : 'Aus'}
				</label>
			{:else if entry.type === 'enum' && entry.choices?.length}
				<select
					{id}
					bind:value={draft as string}
					aria-describedby="{id}-desc"
					class="border-input bg-background focus-visible:ring-ring/50 h-8 w-full rounded-lg border px-2 text-sm outline-none focus-visible:ring-3"
				>
					{#each entry.choices as c (c)}<option value={c}>{c}</option>{/each}
				</select>
			{:else}
				<Input
					{id}
					bind:value={draft as string}
					onblur={() => (touched = true)}
					oninput={() => (touched = true)}
					inputmode={entry.type === 'int' ? 'numeric' : isNumeric(entry) ? 'decimal' : undefined}
					autocomplete="off"
					spellcheck={false}
					class={isNumeric(entry) || entry.type === 'list' ? 'font-mono' : ''}
					aria-invalid={error ? true : undefined}
					aria-describedby="{id}-desc{error ? ` ${id}-err` : ''}"
				/>
			{/if}
			{#if error}
				<p id="{id}-err" role="alert" class="text-destructive text-[13px]">{error}</p>
			{/if}
			<div class="flex flex-wrap gap-2">
				<Button type="submit" size="sm" disabled={!dirty || !parsed.ok}>Speichern</Button>
				<Button
					type="button"
					size="sm"
					variant="outline"
					disabled={!canReset(entry)}
					onclick={() => onreset(entry)}
				>
					<RotateCcwIcon aria-hidden="true" />Auf Standard
				</Button>
			</div>
		{/if}
	</form>
</div>
