<script lang="ts">
	import DataTable from '#lib/design/DataTable.svelte';
	import { formatCompact } from '#lib/format.js';
	import ChartToolbar from './ChartToolbar.svelte';
	import {
		areaPath,
		bandPath,
		bytesUnit,
		colorClass,
		linePath,
		linear,
		nearestIndex,
		niceTicks,
		round,
		tickIndices,
		type SeriesColor
	} from './scale.js';

	export interface XYSeries {
		key: string;
		label: string;
		values: (number | null)[];
		color: SeriesColor;
	}

	let {
		categories,
		ticks,
		series,
		kind = 'line',
		stacked = false,
		format = (v: number) => formatCompact(v),
		axisFormat = (v: number) => formatCompact(v),
		height = 220,
		label,
		yMax,
		zero = true,
		bytes = false,
		firstColumn = 'Zeitpunkt'
	}: {
		categories: string[];
		/** Kurze Achsenbeschriftung je Kategorie; Standard: categories. */
		ticks?: string[];
		series: XYSeries[];
		kind?: 'line' | 'area' | 'bar';
		stacked?: boolean;
		format?: (v: number) => string;
		axisFormat?: (v: number) => string;
		height?: number;
		label: string;
		yMax?: number;
		zero?: boolean;
		/** Achse in Bytes: Ticks auf runden KB/MB/GB. */
		bytes?: boolean;
		firstColumn?: string;
	} = $props();

	const M = { l: 46, r: 10, t: 10, b: 26 };
	let width = $state(640);
	let table = $state(false);
	let active = $state<number | null>(null);
	let wrap: HTMLDivElement | undefined = $state();

	const n = $derived(categories.length);
	const plotW = $derived(Math.max(10, width - M.l - M.r));
	const plotH = $derived(height - M.t - M.b);
	const stackedMode = $derived(stacked && series.length > 1);

	// Gestapelte Summen je Kategorie (Basis und Oberkante je Serie)
	const layers = $derived.by(() => {
		const base = new Array<number>(n).fill(0);
		return series.map((s) => {
			const lo = [...base];
			const hi = s.values.map((v, i) => (stackedMode ? base[i] + (v ?? 0) : (v ?? 0)));
			if (stackedMode) hi.forEach((v, i) => (base[i] = v));
			return { lo: stackedMode ? lo : new Array<number>(n).fill(0), hi };
		});
	});

	const yScale = $derived.by(() => {
		const all = layers.flatMap((l) => l.hi);
		const data = all.length ? Math.max(...all) : 1;
		const vals = series.flatMap((s) => s.values.filter((v): v is number => v !== null));
		const lo = zero || vals.length === 0 ? 0 : Math.min(...vals);
		const unit = bytes ? bytesUnit(data) : 1;
		const nt = niceTicks(lo / unit, (yMax ?? data * 1.04) / unit, 4);
		const t = { ticks: nt.ticks.map((v) => v * unit), min: nt.min * unit, max: nt.max * unit };
		return { ...t, y: linear(t.min, t.max, M.t + plotH, M.t) };
	});

	const hasData = $derived(series.some((s) => s.values.some((v) => (v ?? 0) > 0)));
	const isBar = $derived(kind === 'bar');
	const step = $derived(plotW / Math.max(1, isBar ? n : n - 1));
	const xAt = (i: number) =>
		isBar ? M.l + step * (i + 0.5) : M.l + (n <= 1 ? plotW / 2 : step * i);
	const barW = $derived(Math.max(2, Math.min(34, step * 0.72)));
	const xs = $derived(categories.map((_, i) => xAt(i)));
	const labelW = $derived(Math.max(...(ticks ?? categories).map((c) => c.length), 4) * 6.4 + 18);
	const xTickIdx = $derived(tickIndices(n, Math.max(2, Math.floor(plotW / labelW))));
	const xTickText = (i: number) => (ticks ?? categories)[i];

	function setFromPointer(e: PointerEvent): void {
		const r = wrap?.getBoundingClientRect();
		if (!r || n === 0) return;
		const x = e.clientX - r.left;
		active = isBar
			? Math.min(n - 1, Math.max(0, Math.floor((x - M.l) / step)))
			: nearestIndex(x, M.l, M.l + plotW, n);
	}

	function onkeydown(e: KeyboardEvent): void {
		if (n === 0) return;
		const cur = active ?? (e.key === 'ArrowLeft' ? n : -1);
		if (e.key === 'ArrowRight') active = Math.min(n - 1, cur + 1);
		else if (e.key === 'ArrowLeft') active = Math.max(0, cur - 1);
		else if (e.key === 'Home') active = 0;
		else if (e.key === 'End') active = n - 1;
		else if (e.key === 'Escape') active = null;
		else return;
		e.preventDefault();
	}

	const announce = $derived(
		active === null
			? ''
			: `${categories[active]}: ${series.map((s) => `${s.label} ${s.values[active!] === null ? 'keine Daten' : format(s.values[active!] as number)}`).join(', ')}`
	);
	const tipLeft = $derived(active === null ? 0 : xAt(active));
	const flip = $derived(active !== null && tipLeft > width * 0.55);

	const tableCols = $derived([
		{ key: '_c', label: firstColumn },
		...series.map((s) => ({ key: s.key, label: s.label, align: 'right' as const }))
	]);
	const tableRows = $derived(
		categories.map((c, i) => ({
			_c: c,
			...Object.fromEntries(
				series.map((s) => [s.key, s.values[i] === null ? '–' : format(s.values[i] as number)])
			)
		}))
	);
</script>

<div>
	<ChartToolbar bind:table>
		{#snippet legend()}
			{#each series.length > 1 ? series : [] as s (s.key)}
				<span class="inline-flex items-center gap-1.5">
					<span class="size-2.5 rounded-[3px] {colorClass[s.color].bg}" aria-hidden="true"></span>
					{s.label}
				</span>
			{/each}
		{/snippet}
	</ChartToolbar>

	{#if table}
		<div class="max-h-80 overflow-y-auto rounded-lg border">
			<DataTable caption="{label} als Tabelle" columns={tableCols} rows={tableRows} dense />
		</div>
	{:else}
		<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
		<div
			bind:this={wrap}
			bind:clientWidth={width}
			role="group"
			aria-roledescription="Diagramm"
			aria-label="{label}. Pfeiltasten wählen einen Zeitpunkt, die Tabellenansicht zeigt alle Werte."
			tabindex="0"
			class="relative rounded-md outline-offset-4 select-none"
			{onkeydown}
			onpointermove={setFromPointer}
			onpointerdown={setFromPointer}
			onpointerleave={() => (active = null)}
			onfocus={() => active === null && (active = n - 1)}
			onblur={() => (active = null)}
		>
			<svg {width} {height} role="presentation" class="block touch-pan-y overflow-visible">
				{#each yScale.ticks as t (t)}
					<line
						x1={M.l}
						x2={M.l + plotW}
						y1={round(yScale.y(t))}
						y2={round(yScale.y(t))}
						class={t === yScale.min ? 'stroke-chart-axis' : 'stroke-chart-grid'}
						stroke-width="1"
						stroke-opacity={t === yScale.min ? 0.35 : 1}
					/>
					<text
						x={M.l - 8}
						y={round(yScale.y(t))}
						dy="0.32em"
						text-anchor="end"
						class="fill-chart-axis text-[11px]"
					>
						{axisFormat(t)}
					</text>
				{/each}
				{#each xTickIdx as i (i)}
					<text
						x={xs[i]}
						y={height - 7}
						text-anchor={xTickIdx.length > 1 && i === xTickIdx[0] && !isBar
							? 'start'
							: i === xTickIdx[xTickIdx.length - 1] && !isBar && xTickIdx.length > 1
								? 'end'
								: 'middle'}
						class="fill-chart-axis text-[11px]"
					>
						{xTickText(i)}
					</text>
				{/each}

				{#if active !== null}
					<rect
						x={isBar ? xs[active] - step / 2 : xs[active] - 0.5}
						y={M.t}
						width={isBar ? step : 1}
						height={plotH}
						class="fill-foreground"
						fill-opacity={isBar ? 0.05 : 0.18}
					/>
				{/if}

				{#each series as s, si (s.key)}
					{@const L = layers[si]}
					{@const cc = colorClass[s.color]}
					{#if isBar}
						{#each s.values as v, i (i)}
							{#if v !== null && v > 0}
								{@const bi = stackedMode ? 0 : si}
								{@const gw = stackedMode ? barW : barW / series.length}
								<rect
									x={round(xs[i] - barW / 2 + bi * gw)}
									y={round(yScale.y(L.hi[i]))}
									width={round(Math.max(1, gw - (stackedMode ? 0 : 1)))}
									height={round(
										Math.max(0, yScale.y(L.lo[i]) - yScale.y(L.hi[i]) - (stackedMode ? 0.75 : 0))
									)}
									rx="1.5"
									class={cc.fill}
									opacity={active === null || active === i ? 1 : 0.55}
								/>
							{/if}
						{/each}
					{:else}
						{#if kind === 'area' && s.values.every((v) => v !== null)}
							<path
								d={stackedMode
									? bandPath(xs, L.hi.map(yScale.y), L.lo.map(yScale.y))
									: areaPath(xs, L.hi.map(yScale.y), yScale.y(yScale.min))}
								class={cc.fill}
								fill-opacity={stackedMode ? 0.55 : 0.14}
							/>
						{/if}
						<path
							d={linePath(
								xs,
								L.hi.map((v, i) => (s.values[i] === null ? null : yScale.y(v)))
							)}
							class={cc.stroke}
							fill="none"
							stroke-width="2"
							stroke-linejoin="round"
							stroke-linecap="round"
						/>
						{#if active !== null && s.values[active] !== null}
							<circle
								cx={xs[active]}
								cy={yScale.y(L.hi[active])}
								r="4"
								class="{cc.fill} stroke-card"
								stroke-width="2"
							/>
						{/if}
						<!-- Einzelwerte zwischen Luecken (null) haben keine Linie: als Punkt zeichnen. -->
						{#each s.values as v, i (i)}
							{#if v !== null && s.values[i - 1] == null && s.values[i + 1] == null}
								<circle cx={xs[i]} cy={yScale.y(L.hi[i])} r="3.5" class={cc.fill} />
							{/if}
						{/each}
					{/if}
				{/each}
			</svg>

			{#if active !== null}
				<div
					class="bg-popover text-popover-foreground shadow-pop pointer-events-none absolute top-1 z-20 min-w-36 rounded-lg border px-3 py-2 text-[13px] {flip
						? '-translate-x-full'
						: ''}"
					style:left="{tipLeft + (flip ? -12 : 12)}px"
				>
					<p class="mb-1 font-medium">{categories[active]}</p>
					{#each series as s (s.key)}
						<p class="flex items-center justify-between gap-4">
							<span class="text-muted-foreground inline-flex items-center gap-1.5">
								<span class="size-2 rounded-full {colorClass[s.color].bg}" aria-hidden="true"
								></span>
								{s.label}
							</span>
							<span class="num font-medium">
								{s.values[active] === null ? '–' : format(s.values[active] as number)}
							</span>
						</p>
					{/each}
				</div>
			{/if}
			{#if !hasData}
				<p
					class="text-muted-foreground pointer-events-none absolute inset-x-0 top-1/3 text-center text-[13px]"
				>
					Keine Werte im Zeitraum.
				</p>
			{/if}
			<div class="sr-only" aria-live="polite">{announce}</div>
		</div>
	{/if}
</div>
