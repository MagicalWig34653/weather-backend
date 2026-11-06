<script lang="ts">
	import { untrack } from 'svelte';
	import RotateCcwIcon from '@lucide/svelte/icons/rotate-ccw';
	import type { ConfigEntry } from '#lib/api.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import StatusDot from '#lib/design/StatusDot.svelte';
	import { canReset, valuesEqual, validateValue } from './form.js';
	import { checkPair, fromInput, toInput, unitSuffix, type ThresholdRow } from './thresholds.js';

	let {
		row,
		onsave,
		onreset
	}: {
		row: ThresholdRow;
		onsave: (changes: { entry: ConfigEntry; value: number }[]) => void;
		onreset: (entries: ConfigEntry[]) => void;
	} = $props();

	const def = $derived(row.def);
	const entries = $derived([row.yellow, row.red].filter((e): e is ConfigEntry => !!e));
	let yellow = $state(untrack(() => toInput(def.unit, row.yellow?.value ?? null)));
	let red = $state(untrack(() => toInput(def.unit, row.red?.value ?? null)));
	let touched = $state(false);

	let seen = untrack(() => JSON.stringify([row.yellow?.value, row.red?.value]));
	$effect(() => {
		const now = JSON.stringify([row.yellow?.value, row.red?.value]);
		if (now === seen) return;
		seen = now;
		yellow = toInput(def.unit, row.yellow?.value ?? null);
		red = toInput(def.unit, row.red?.value ?? null);
		touched = false;
	});

	function one(
		entry: ConfigEntry | undefined,
		text: string
	): { value: number | null; error: string | null } {
		if (!entry) return { value: null, error: null };
		const n = fromInput(def.unit, text);
		if (n === null) return { value: null, error: 'Bitte eine Zahl eingeben.' };
		const v = validateValue(entry, n);
		if (!v.ok) {
			// Grenzen des Registers in der Einheit der Eingabe nennen
			const lo = entry.min === null ? null : toInput(def.unit, entry.min);
			const hi = entry.max === null ? null : toInput(def.unit, entry.max);
			return {
				value: null,
				error: `Erlaubt sind Werte von ${lo ?? '…'} bis ${hi ?? '…'} ${unitSuffix(def.unit)}.`
			};
		}
		return { value: n, error: null };
	}
	const y = $derived(one(row.yellow, yellow));
	const r = $derived(one(row.red, red));
	const pair = $derived(
		y.value !== null && r.value !== null ? checkPair(def, y.value, r.value) : null
	);
	const changes = $derived(
		[
			row.yellow && y.value !== null && !valuesEqual(y.value, row.yellow.value)
				? { entry: row.yellow, value: y.value }
				: null,
			row.red && r.value !== null && !valuesEqual(r.value, row.red.value)
				? { entry: row.red, value: r.value }
				: null
		].filter((c): c is { entry: ConfigEntry; value: number } => c !== null)
	);
	const valid = $derived(!y.error && !r.error && !pair);
	const locked = $derived(entries.some((e) => e.locked));
	const resettable = $derived(entries.filter(canReset));
	const idY = $derived(`thr-${def.rule}-y`);
	const idR = $derived(`thr-${def.rule}-r`);
	const err = $derived(touched ? (y.error ?? r.error ?? pair) : null);
</script>

<form
	class="grid gap-3 py-4 not-first:border-t first:pt-0 last:pb-0 md:grid-cols-[minmax(0,1fr)_auto] md:items-start md:gap-8"
	novalidate
	onsubmit={(ev) => {
		ev.preventDefault();
		touched = true;
		if (valid && changes.length) onsave(changes);
	}}
>
	<div class="min-w-0">
		<p class="text-sm font-medium">{def.label}</p>
		<p class="text-muted-foreground text-[13px] leading-5">
			{def.hint}
			{def.direction === 'above' ? 'Befund bei Werten darüber.' : 'Befund bei Werten darunter.'}
		</p>
		<p class="text-muted-foreground font-mono text-[11px]">DASH_WARN_{def.rule}_YELLOW / _RED</p>
	</div>
	<div class="space-y-2">
		<div class="flex flex-wrap items-end gap-3">
			{#each [{ id: idY, tone: 'warn', label: 'Warnung', e: row.yellow }, { id: idR, tone: 'err', label: 'Kritisch', e: row.red }] as f (f.id)}
				{#if f.e}
					<div class="w-28 space-y-1">
						<label for={f.id} class="flex items-center gap-1.5 text-xs font-medium">
							<StatusDot tone={f.tone as 'warn' | 'err'} />{f.label}
						</label>
						<div class="relative">
							{#if f.id === idY}
								<Input
									id={f.id}
									bind:value={yellow}
									oninput={() => (touched = true)}
									inputmode="decimal"
									autocomplete="off"
									disabled={f.e.locked}
									class="pr-12 font-mono"
									aria-invalid={err ? true : undefined}
									aria-describedby="thr-{def.rule}-err"
								/>
							{:else}
								<Input
									id={f.id}
									bind:value={red}
									oninput={() => (touched = true)}
									inputmode="decimal"
									autocomplete="off"
									disabled={f.e.locked}
									class="pr-12 font-mono"
									aria-invalid={err ? true : undefined}
									aria-describedby="thr-{def.rule}-err"
								/>
							{/if}
							<span
								class="text-muted-foreground pointer-events-none absolute inset-y-0 right-2.5 flex items-center text-xs"
								aria-hidden="true">{unitSuffix(def.unit)}</span
							>
						</div>
					</div>
				{/if}
			{/each}
		</div>
		{#if err}<p id="thr-{def.rule}-err" role="alert" class="text-destructive max-w-xs text-[13px]">
				{err}
			</p>{/if}
		{#if locked}
			<p class="text-muted-foreground text-xs">Per Umgebungsvariable festgelegt.</p>
		{:else}
			<div class="flex flex-wrap gap-2">
				<Button type="submit" size="sm" disabled={!changes.length || !valid}>Speichern</Button>
				<Button
					type="button"
					size="sm"
					variant="outline"
					disabled={!resettable.length}
					onclick={() => onreset(resettable)}
				>
					<RotateCcwIcon aria-hidden="true" />Auf Standard
				</Button>
			</div>
		{/if}
	</div>
</form>
