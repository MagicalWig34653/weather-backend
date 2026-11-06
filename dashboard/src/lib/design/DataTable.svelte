<script lang="ts" module>
	import type { Snippet } from 'svelte';

	export interface Column<R> {
		key: string;
		label: string;
		align?: 'left' | 'right';
		/** Zellentext; Standard: String(row[key]). */
		format?: (row: R) => string;
		/** Eigene Darstellung (Badges etc.). */
		cell?: Snippet<[R]>;
		class?: string;
	}
</script>

<script lang="ts" generics="Row extends object">
	let {
		columns,
		rows,
		caption,
		rowKey,
		empty = 'Keine Einträge.',
		dense = false
	}: {
		columns: Column<Row>[];
		rows: Row[];
		caption: string;
		rowKey?: (row: Row, i: number) => string | number;
		empty?: string;
		dense?: boolean;
	} = $props();
</script>

<!-- Horizontal scrollbar mit fixierter erster Spalte; Tabellen bleiben auf dem Telefon bedienbar. -->
<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
<div class="overflow-x-auto" role="region" aria-label={caption} tabindex="0">
	<table class="w-full border-separate border-spacing-0 text-[13px]">
		<caption class="sr-only">{caption}</caption>
		<thead>
			<tr>
				{#each columns as c, i (c.key)}
					<th
						scope="col"
						class="text-muted-foreground bg-card border-b px-4 py-2 text-[12px] font-medium whitespace-nowrap {c.align ===
						'right'
							? 'text-right'
							: 'text-left'} {i === 0 ? 'sticky left-0 z-10 sm:px-5' : ''}"
					>
						{c.label}
					</th>
				{/each}
			</tr>
		</thead>
		<tbody>
			{#each rows as row, ri (rowKey ? rowKey(row, ri) : ri)}
				<tr class="group">
					{#each columns as c, i (c.key)}
						<td
							class="group-hover:bg-muted/60 border-b px-4 {dense
								? 'py-1.5'
								: 'py-2.5'} whitespace-nowrap group-last:border-b-0 {c.align === 'right'
								? 'num text-right'
								: 'text-left'} {i === 0
								? 'bg-card group-hover:bg-muted sticky left-0 font-medium sm:px-5'
								: ''} {c.class ?? ''}"
						>
							{#if c.cell}{@render c.cell(row)}{:else}{c.format
									? c.format(row)
									: String((row as Record<string, unknown>)[c.key] ?? '–')}{/if}
						</td>
					{/each}
				</tr>
			{:else}
				<tr
					><td colspan={columns.length} class="text-muted-foreground px-5 py-6 text-center"
						>{empty}</td
					></tr
				>
			{/each}
		</tbody>
	</table>
</div>
