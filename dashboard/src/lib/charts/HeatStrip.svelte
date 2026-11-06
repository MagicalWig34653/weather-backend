<script lang="ts">
	import DataTable from '#lib/design/DataTable.svelte';
	import ChartToolbar from './ChartToolbar.svelte';

	export interface HeatCell {
		/** Text fuer Readout und Tabelle, z. B. "Mi 14:00: 3 Läufe, 1 Fehler". */
		label: string;
		/** Status-Ton (Heat-Strip) oder Intensitaet 0..1 (Heatmap). */
		tone?: 'ok' | 'warn' | 'err' | 'none';
		v?: number;
	}
	export interface HeatRow {
		label: string;
		cells: HeatCell[];
	}
	let {
		rows,
		label,
		keys = [],
		cellHeight = 28,
		axis
	}: {
		rows: HeatRow[];
		label: string;
		keys?: { tone: 'ok' | 'warn' | 'err' | 'none'; label: string }[];
		cellHeight?: number;
		/** Beschriftungen unter dem Streifen (links, rechts). */
		axis?: [string, string];
	} = $props();

	let table = $state(false);
	let ar = $state(0);
	let ac = $state<number | null>(null);

	const cols = $derived(Math.max(1, ...rows.map((r) => r.cells.length)));
	const intensity = $derived(rows.some((r) => r.cells.some((c) => c.tone === undefined)));
	const readout = $derived(
		ac === null
			? ''
			: `${rows[ar]?.label ? rows[ar].label + ': ' : ''}${rows[ar]?.cells[ac]?.label ?? ''}`
	);

	const fill = {
		ok: 'bg-ok-fill',
		warn: 'bg-warn-fill',
		err: 'bg-err-fill',
		none: 'bg-chart-empty'
	};
	/** Hoehe als zweiter Kanal neben der Farbe (Farbfehlsichtigkeit). */
	const heightPct = { ok: 55, warn: 78, err: 100, none: 26 };

	function onkeydown(e: KeyboardEvent): void {
		if (!rows.length) return;
		const c = ac ?? 0;
		if (e.key === 'ArrowRight') ac = Math.min(cols - 1, c + 1);
		else if (e.key === 'ArrowLeft') ac = Math.max(0, c - 1);
		else if (e.key === 'ArrowDown') ar = Math.min(rows.length - 1, ar + 1);
		else if (e.key === 'ArrowUp') ar = Math.max(0, ar - 1);
		else if (e.key === 'Home') ac = 0;
		else if (e.key === 'End') ac = cols - 1;
		else if (e.key === 'Escape') ac = null;
		else return;
		if (ac === null) ac = c;
		e.preventDefault();
	}

	const flat = $derived(
		rows.flatMap((r) => r.cells.map((c) => ({ row: r.label, cell: c.label }))).slice(0, 4000)
	);
</script>

<div>
	<ChartToolbar bind:table>
		{#snippet legend()}
			{#each keys as l (l.tone)}
				<span class="inline-flex items-center gap-1.5">
					<span
						class="inline-block w-2.5 rounded-[3px] {fill[l.tone]}"
						style:height="{heightPct[l.tone] / 10 + 4}px"
						aria-hidden="true"
					></span>
					{l.label}
				</span>
			{/each}
			{#if intensity}
				<span class="inline-flex items-center gap-1.5">
					wenig
					<span
						class="bg-chart-1 inline-block h-2.5 w-16 rounded-[3px] opacity-100 [mask-image:linear-gradient(90deg,transparent,#000)]"
						aria-hidden="true"
					></span>
					viel
				</span>
			{/if}
		{/snippet}
	</ChartToolbar>

	{#if table}
		<div class="max-h-80 overflow-y-auto rounded-lg border">
			<DataTable
				caption="{label} als Tabelle"
				columns={[
					{ key: 'row', label: 'Bereich' },
					{ key: 'cell', label: 'Wert' }
				]}
				rows={flat}
				dense
			/>
		</div>
	{:else}
		<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
		<div
			role="group"
			aria-roledescription="Heat-Strip"
			aria-label="{label}. Pfeiltasten wählen eine Zelle."
			tabindex="0"
			class="rounded-md outline-offset-4"
			{onkeydown}
			onfocus={() => ac === null && (ac = cols - 1)}
			onblur={() => (ac = null)}
			onpointerleave={() => (ac = null)}
		>
			<div class="flex flex-col gap-1.5">
				{#each rows as r, ri (r.label + ri)}
					<div class="flex items-center gap-3">
						{#if r.label}
							<span class="text-muted-foreground w-20 shrink-0 truncate text-[12px] sm:w-28"
								>{r.label}</span
							>
						{/if}
						<div
							class="grid min-w-0 flex-1 gap-[2px]"
							style:grid-template-columns="repeat({cols}, minmax(0, 1fr))"
							style:height="{cellHeight}px"
						>
							{#each r.cells as c, ci (ci)}
								<!-- svelte-ignore a11y_no_static_element_interactions -->
								<div
									class="flex items-end"
									onpointerenter={() => ((ar = ri), (ac = ci))}
									onpointerdown={() => ((ar = ri), (ac = ci))}
								>
									<div
										class="w-full rounded-[2px] {c.tone ? fill[c.tone] : 'bg-chart-1'} {ac === ci &&
										ar === ri
											? 'outline-foreground outline outline-2 -outline-offset-1'
											: ''}"
										style:height={c.tone ? `${heightPct[c.tone]}%` : '100%'}
										style:opacity={c.tone ? 1 : Math.max(0.06, c.v ?? 0)}
									></div>
								</div>
							{/each}
						</div>
					</div>
				{/each}
			</div>
			{#if axis}
				<div
					class="text-muted-foreground mt-1.5 flex justify-between text-[11px] {rows[0]?.label
						? 'pl-[5.75rem] sm:pl-[8.25rem]'
						: ''}"
				>
					<span>{axis[0]}</span><span>{axis[1]}</span>
				</div>
			{/if}
			<p class="num text-muted-foreground mt-2 min-h-5 text-[13px]" aria-live="polite">
				{readout || 'Zelle wählen für Details.'}
			</p>
		</div>
	{/if}
</div>
