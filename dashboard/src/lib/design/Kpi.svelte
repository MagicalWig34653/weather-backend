<script lang="ts">
	import ArrowUpRightIcon from '@lucide/svelte/icons/arrow-up-right';
	import ArrowDownRightIcon from '@lucide/svelte/icons/arrow-down-right';
	import MinusIcon from '@lucide/svelte/icons/minus';
	import Sparkline from '#lib/charts/Sparkline.svelte';
	import { formatDelta } from '#lib/format.js';
	import StatusDot from './StatusDot.svelte';
	import { toneLabel, toneText, type Tone } from './tone.js';

	let {
		label,
		value,
		unit,
		delta = null,
		goodWhen = 'up',
		deltaLabel = 'ggü. Vorzeitraum',
		series,
		tone,
		hint
	}: {
		label: string;
		value: string;
		unit?: string;
		/** Relative Aenderung (0,12 = +12 %); null = nicht verfuegbar. */
		delta?: number | null;
		/** Welche Richtung gut ist: bestimmt nur die Farbe, der Pfeil zeigt immer die Richtung. */
		goodWhen?: 'up' | 'down' | 'none';
		deltaLabel?: string;
		series?: number[];
		tone?: Tone;
		hint?: string;
	} = $props();

	const flat = $derived(delta === null || Math.abs(delta) < 0.005);
	const up = $derived((delta ?? 0) > 0);
	const deltaTone = $derived<Tone>(
		flat || goodWhen === 'none'
			? 'neutral'
			: (up ? goodWhen === 'up' : goodWhen === 'down')
				? 'ok'
				: 'warn'
	);
</script>

<div class="bg-card shadow-card flex min-w-0 flex-col gap-1 rounded-xl border p-3.5 sm:p-5">
	<div class="flex items-center gap-2">
		{#if tone}<StatusDot {tone} label={toneLabel[tone]} />{/if}
		<p class="text-muted-foreground truncate text-[13px] font-medium">{label}</p>
	</div>
	<p
		class="num flex items-baseline gap-1 text-[22px] leading-8 sm:text-[28px] sm:leading-9 font-semibold tracking-tight"
	>
		{value}{#if unit}<span class="text-muted-foreground text-sm font-medium">{unit}</span>{/if}
	</p>
	<div class="flex min-h-9 items-end justify-between gap-3">
		<div class="min-w-0 text-[13px] leading-5">
			{#if delta !== null}
				<p class="num flex items-center gap-1 font-medium {toneText[deltaTone]}">
					{#if flat}<MinusIcon class="size-3.5" aria-hidden="true" />
					{:else if up}<ArrowUpRightIcon class="size-3.5" aria-hidden="true" />
					{:else}<ArrowDownRightIcon class="size-3.5" aria-hidden="true" />{/if}
					{formatDelta(delta)}
				</p>
				<p class="text-muted-foreground truncate">{deltaLabel}</p>
			{:else if hint}
				<p class="text-muted-foreground">{hint}</p>
			{/if}
		</div>
		{#if series && series.length > 1}
			<Sparkline values={series} class="hidden h-9 w-28 shrink-0 sm:block" />
		{/if}
	</div>
</div>
