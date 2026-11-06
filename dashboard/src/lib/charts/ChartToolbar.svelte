<script lang="ts">
	import type { Snippet } from 'svelte';
	import TableIcon from '@lucide/svelte/icons/table-2';
	import ChartIcon from '@lucide/svelte/icons/chart-column';
	let { table = $bindable(false), legend }: { table?: boolean; legend?: Snippet } = $props();
</script>

<div class="mb-2 flex items-center justify-between gap-3">
	<div
		class="text-muted-foreground flex min-w-0 flex-wrap items-center gap-x-4 gap-y-1 text-[13px]"
	>
		{@render legend?.()}
	</div>
	<button
		type="button"
		aria-pressed={table}
		onclick={() => (table = !table)}
		class="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md px-2.5 text-xs font-medium"
	>
		{#if table}<ChartIcon class="size-3.5" aria-hidden="true" /> Diagramm{:else}<TableIcon
				class="size-3.5"
				aria-hidden="true"
			/> Tabelle{/if}
	</button>
</div>
