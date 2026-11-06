<script lang="ts">
	import { colorClass, type SeriesColor } from './scale.js';

	export interface DonutPart {
		label: string;
		value: number;
		color: SeriesColor;
	}
	let {
		parts,
		label,
		centerValue,
		centerLabel,
		format = (v: number) => String(v)
	}: {
		parts: DonutPart[];
		label: string;
		centerValue?: string;
		centerLabel?: string;
		format?: (v: number) => string;
	} = $props();

	const total = $derived(parts.reduce((s, p) => s + p.value, 0));
	const R = 42;
	const arcs = $derived.by(() => {
		let acc = 0;
		return parts.map((p) => {
			const pct = total ? (p.value / total) * 100 : 0;
			const a = { ...p, pct, offset: -acc };
			acc += pct;
			return a;
		});
	});
</script>

<div class="flex flex-wrap items-center gap-x-6 gap-y-4">
	<svg viewBox="0 0 100 100" class="size-32 shrink-0 -rotate-90" role="img" aria-label={label}>
		<circle cx="50" cy="50" r={R} fill="none" stroke-width="10" class="stroke-chart-empty" />
		{#each arcs as a (a.label)}
			{#if a.pct > 0}
				<circle
					cx="50"
					cy="50"
					r={R}
					fill="none"
					stroke-width="10"
					pathLength="100"
					stroke-dasharray="{Math.max(0, a.pct - (arcs.length > 1 ? 0.8 : 0))} {100 -
						Math.max(0, a.pct - (arcs.length > 1 ? 0.8 : 0))}"
					stroke-dashoffset={a.offset}
					class={colorClass[a.color].stroke}
				/>
			{/if}
		{/each}
	</svg>
	{#if centerValue}
		<!-- Mittelwert liegt ueber dem Ring (rotierter SVG-Text waere schwer lesbar). -->
		<div class="-ml-[calc(8rem+1.5rem)] flex size-32 shrink-0 flex-col items-center justify-center">
			<span class="num text-xl font-semibold">{centerValue}</span>
			{#if centerLabel}<span class="text-muted-foreground text-[11px]">{centerLabel}</span>{/if}
		</div>
	{/if}
	<ul class="grid min-w-40 flex-1 gap-1.5 text-[13px]" aria-label="{label}, Werte">
		{#each arcs as a (a.label)}
			<li class="flex items-center justify-between gap-4">
				<span class="inline-flex items-center gap-2">
					<span class="size-2.5 rounded-[3px] {colorClass[a.color].bg}" aria-hidden="true"></span>
					{a.label}
				</span>
				<span class="num font-medium">
					{format(a.value)}
					<span class="text-muted-foreground font-normal">
						{new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 }).format(a.pct)} %
					</span>
				</span>
			</li>
		{/each}
	</ul>
</div>
