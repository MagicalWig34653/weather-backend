<script lang="ts">
	import { colorClass, type SeriesColor } from './scale.js';

	export interface RankItem {
		label: string;
		value: number;
		/** Anzeigewert; Standard: format(value). */
		display?: string;
		/** Zweitinfo rechts neben dem Wert (z. B. Anteil). */
		note?: string;
		color?: SeriesColor;
		mono?: boolean;
	}
	let {
		items,
		format = (v: number) => String(v),
		color = 1,
		label,
		max
	}: {
		items: RankItem[];
		format?: (v: number) => string;
		color?: SeriesColor;
		label: string;
		max?: number;
	} = $props();

	const top = $derived(max ?? Math.max(1, ...items.map((i) => i.value)));
</script>

<!-- Horizontale Rangbalken, Nullbasis, direkte Beschriftung: die Liste ist zugleich die Textalternative. -->
<ul class="flex flex-col gap-3" aria-label={label}>
	{#each items as it (it.label)}
		<li class="grid gap-1">
			<div class="flex items-baseline justify-between gap-3 text-[13px]">
				<span class="min-w-0 truncate {it.mono ? 'font-mono text-xs' : 'font-medium'}"
					>{it.label}</span
				>
				<span class="num shrink-0 font-medium">
					{it.display ?? format(it.value)}
					{#if it.note}<span class="text-muted-foreground ml-1.5 font-normal">{it.note}</span>{/if}
				</span>
			</div>
			<div class="bg-muted h-2 overflow-hidden rounded-full" aria-hidden="true">
				<div
					class="h-full rounded-full {colorClass[it.color ?? color].bg}"
					style:width="{Math.max(it.value > 0 ? 1.5 : 0, (it.value / top) * 100)}%"
				></div>
			</div>
		</li>
	{/each}
</ul>
