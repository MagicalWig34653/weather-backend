<script lang="ts">
	import { formatDay } from '#lib/format.js';

	interface Series {
		key: string;
		label: string;
		/** Tailwind-Fuellklasse, z. B. "fill-chart-1" */
		fill: string;
		/** passende Hintergrundklasse fuer die Legende */
		swatch: string;
	}
	interface Day {
		date: string;
		values: Record<string, number>;
	}

	let {
		days,
		series,
		format,
		label
	}: { days: Day[]; series: Series[]; format: (n: number) => string; label: string } = $props();

	const W = 720;
	const H = 220;
	const pad = { l: 56, r: 8, t: 8, b: 24 };

	const totals = $derived(days.map((d) => series.reduce((s, x) => s + (d.values[x.key] ?? 0), 0)));
	const max = $derived(niceMax(Math.max(1, ...totals)));
	const bw = $derived((W - pad.l - pad.r) / Math.max(1, days.length));

	function niceMax(v: number): number {
		const p = 10 ** Math.floor(Math.log10(v));
		for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
		return 10 * p;
	}
	const y = (v: number) => pad.t + (H - pad.t - pad.b) * (1 - v / max);
	const ticks = $derived([0, 0.5, 1].map((f) => max * f));

	function bars(d: Day): { s: Series; y: number; h: number }[] {
		let acc = 0;
		return series.map((s) => {
			const v = d.values[s.key] ?? 0;
			const top = y(acc + v);
			const h = y(acc) - top;
			acc += v;
			return { s, y: top, h };
		});
	}
</script>

<figure class="space-y-3">
	<table class="sr-only">
		<caption>{label}</caption>
		<thead>
			<tr
				><th>Tag</th>{#each series as s (s.key)}<th>{s.label}</th>{/each}</tr
			>
		</thead>
		<tbody>
			{#each days as d (d.date)}
				<tr>
					<td>{formatDay(d.date)}</td>
					{#each series as s (s.key)}<td>{format(d.values[s.key] ?? 0)}</td>{/each}
				</tr>
			{/each}
		</tbody>
	</table>
	<svg viewBox="0 0 {W} {H}" class="h-auto w-full" role="img" aria-label={label}>
		{#each ticks as t (t)}
			<line x1={pad.l} x2={W - pad.r} y1={y(t)} y2={y(t)} class="stroke-border" stroke-width="1" />
			<text x={pad.l - 6} y={y(t) + 4} text-anchor="end" class="fill-muted-foreground text-[11px]">
				{format(t)}
			</text>
		{/each}
		{#each days as d, i (d.date)}
			<g>
				<title>{formatDay(d.date)}: {format(totals[i])}</title>
				{#each bars(d) as b (b.s.key)}
					<rect
						x={pad.l + i * bw + 1}
						y={b.y}
						width={Math.max(1, bw - 2)}
						height={Math.max(0, b.h)}
						class={b.s.fill}
					/>
				{/each}
			</g>
			{#if i % 5 === 0 || i === days.length - 1}
				<text
					x={pad.l + i * bw + bw / 2}
					y={H - 6}
					text-anchor="middle"
					class="fill-muted-foreground text-[11px]">{formatDay(d.date)}</text
				>
			{/if}
		{/each}
	</svg>
	<figcaption class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
		{#each series as s (s.key)}
			<span class="inline-flex items-center gap-1.5">
				<span class="inline-block size-3 rounded-sm {s.swatch}" aria-hidden="true"></span>
				{s.label}
			</span>
		{/each}
	</figcaption>
</figure>
