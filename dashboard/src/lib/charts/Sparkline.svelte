<script lang="ts">
	import { areaPath, linePath, linear } from './scale.js';
	let { values, class: className = 'h-9 w-28' }: { values: number[]; class?: string } = $props();

	const W = 112;
	const H = 36;
	const geo = $derived.by(() => {
		const min = Math.min(...values);
		const max = Math.max(...values);
		const x = linear(0, values.length - 1, 2, W - 4);
		const y = linear(min === max ? min - 1 : min, max === min ? max + 1 : max, H - 3, 3);
		const xs = values.map((_, i) => x(i));
		const ys = values.map((v) => y(v));
		return { xs, ys };
	});
</script>

<!-- Zierde: der Wert steht im Text der Kachel. -->
<svg viewBox="0 0 {W} {H}" class={className} preserveAspectRatio="none" aria-hidden="true">
	<path d={areaPath(geo.xs, geo.ys, H)} class="fill-chart-1" fill-opacity="0.12" />
	<path
		d={linePath(geo.xs, geo.ys)}
		class="stroke-chart-1"
		fill="none"
		stroke-width="1.75"
		stroke-linejoin="round"
		stroke-linecap="round"
		vector-effect="non-scaling-stroke"
	/>
</svg>
