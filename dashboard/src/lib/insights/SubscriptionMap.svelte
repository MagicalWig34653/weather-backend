<script lang="ts">
	import { insights } from './api.js';
	import { mapWindow, graticule } from './grid.js';
	import { classText } from './text.js';
	import { formatDateTime } from '#lib/format.js';
	import type { DeviceSubscriptions } from './types.js';

	/**
	 * Karte der Abo-Orte ohne Kartendienst: Ausschnitt der Radar-Analyse (Slot 0) des ausgewerteten Laufs aus dem Cache des Servers
	 * (gleiche Herkunft, `img-src 'self'`), darüber Gradnetz, Rasterzelle und Umkreis als SVG in Zellkoordinaten.
	 * Es gibt keine Anfrage an Dritte; Koordinaten verlassen das Dashboard nicht.
	 */
	let { data }: { data: DeviceSubscriptions } = $props();

	const grid = $derived({
		width: data.radar.gridWidth ?? 1024,
		height: data.radar.gridHeight ?? 1311
	});
	const g = $derived({
		width: grid.width,
		height: grid.height,
		bbox: [612257.0, 5942074.0, 1736584.0, 7381298.0] as const,
		earthRadius: 6378137.0
	});
	const marks = $derived(
		data.subscriptions.flatMap((s) =>
			s.place
				? [
						{
							n: s.index + 1,
							x: s.place.x,
							y: s.place.y,
							radius: s.kind === 'circle' ? (s.radiusCells ?? 0) : 0,
							wet: (s.measuredClass ?? 0) >= s.thresholdClass,
							rain: (s.measuredClass ?? 0) > 0,
							cls: s.measuredClass ?? null,
							enabled: s.enabled
						}
					]
				: []
		)
	);
	const win = $derived(mapWindow(marks, g));
	const grat = $derived(graticule(win, g));
	const run = $derived(data.radar.runNominal ?? null);
	const src = $derived(run ? insights.cachePreviewUrl('radar', run, run) : '');
	let failed = $state(false);
	$effect(() => {
		void src;
		failed = false;
	});
	const pct = (v: number): string => `${(v / win.size) * 100}%`;
	const fmt = (v: number): string => String(v).replace('.', ',');
	// Schriftgrad und Markergroesse in Zellen: der Ausschnitt skaliert alles gleichmaessig.
	const u = $derived(win.size / 100);
</script>

{#if marks.length > 0}
	<figure class="m-0 mb-4">
		<div
			class="relative mx-auto aspect-square w-full max-w-[28rem] overflow-hidden rounded-xl border bg-[#14202e] shadow-sm"
		>
			{#if src && !failed}
				<img
					{src}
					alt=""
					width={grid.width}
					height={grid.height}
					decoding="async"
					class="absolute max-w-none"
					style="image-rendering: pixelated; width: {((grid.width / win.size) * 100).toFixed(
						3
					)}%; height: {((grid.height / win.size) * 100).toFixed(3)}%; left: -{pct(
						win.x0
					)}; top: -{pct(win.y0)};"
					onerror={() => (failed = true)}
				/>
			{/if}
			<svg
				viewBox="{win.x0} {win.y0} {win.size} {win.size}"
				class="absolute inset-0 size-full"
				role="img"
				aria-label="Karte der Abo-Orte mit Rasterzelle, Umkreis und Radarintensität darunter"
			>
				<g stroke="#ffffff" stroke-opacity="0.22" stroke-width="1" fill="none">
					{#each grat.lines as l (l.kind + l.value)}
						{#if l.kind === 'lat'}
							<line
								x1={win.x0}
								x2={win.x0 + win.size}
								y1={l.at}
								y2={l.at}
								vector-effect="non-scaling-stroke"
							/>
						{:else}
							<line
								y1={win.y0}
								y2={win.y0 + win.size}
								x1={l.at}
								x2={l.at}
								vector-effect="non-scaling-stroke"
							/>
						{/if}
					{/each}
				</g>
				<g fill="#ffffff" fill-opacity="0.6" font-size={u * 2.6} font-family="Inter, sans-serif">
					{#each grat.lines as l (l.kind + l.value)}
						{#if l.kind === 'lat'}
							<text x={win.x0 + u * 0.8} y={l.at - u * 0.6}>{fmt(l.value)}° N</text>
						{:else}
							<text x={l.at + u * 0.8} y={win.y0 + win.size - u * 0.8}>{fmt(l.value)}° O</text>
						{/if}
					{/each}
				</g>
				{#each marks as m (m.n)}
					{#if m.radius > 0}
						<circle
							cx={m.x + 0.5}
							cy={m.y + 0.5}
							r={m.radius}
							fill={m.wet ? '#38bdf8' : '#ffffff'}
							fill-opacity="0.08"
							stroke="#ffffff"
							stroke-width="2"
							stroke-dasharray="6 4"
							vector-effect="non-scaling-stroke"
						/>
					{/if}
					<rect
						x={m.x - u * 0.8}
						y={m.y - u * 0.8}
						width={u * 2.6}
						height={u * 2.6}
						fill="none"
						stroke={m.enabled ? '#facc15' : '#9ca3af'}
						stroke-width="2"
						vector-effect="non-scaling-stroke"
					/>
					<circle cx={m.x + 0.5} cy={m.y + 0.5} r={u * 0.4} fill="#facc15" />
					<text
						x={m.x + u * 2.2}
						y={m.y - u * 1.2}
						font-size={u * 4}
						font-weight="700"
						fill="#ffffff"
						stroke="#14202e"
						stroke-width="3"
						paint-order="stroke"
						font-family="Inter, sans-serif">{m.n}</text
					>
				{/each}
			</svg>
			{#if failed || !src}
				<p
					class="text-muted-foreground absolute inset-x-0 top-0 bg-black/40 px-3 py-1.5 text-center text-[12px] text-white"
				>
					Radarbild nicht verfügbar (Lauf fehlt oder Sitzung).
				</p>
			{/if}
		</div>
		<figcaption class="text-muted-foreground mx-auto mt-2 max-w-[28rem] text-[12px]">
			Gelbes Quadrat: Rasterzelle des Abos (etwa 0,7 km), gestrichelt: Umkreis. Hintergrund:
			Radar-Analyse
			{#if run}vom <time datetime={run}>{formatDateTime(run)}</time>{/if} (die Farben der DWD-Legende,
			keine Landkarte), darüber das Gradnetz.
			{#each marks as m (m.n)}
				<span class="block">Abo {m.n}: {m.cls === null ? 'keine Messung' : classText(m.cls)}</span>
			{/each}
		</figcaption>
	</figure>
{/if}
