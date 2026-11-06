<script lang="ts">
	import Skeleton from '#lib/design/Skeleton.svelte';
	let { kind = 'chart' }: { kind?: 'chart' | 'kpis' | 'list' | 'strip' } = $props();
</script>

{#if kind === 'kpis'}
	<div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
		{#each [0, 1, 2, 3, 4, 5] as i (i)}
			<div class="bg-card flex h-[140px] flex-col gap-3 rounded-xl border p-5">
				<Skeleton class="h-3.5 w-24" /><Skeleton class="h-8 w-32" /><Skeleton class="h-4 w-40" />
			</div>
		{/each}
	</div>
{:else if kind === 'list'}
	<div class="flex flex-col gap-4">
		{#each [0, 1, 2, 3] as i (i)}<Skeleton class="h-8 w-full" />{/each}
	</div>
{:else if kind === 'strip'}
	<div class="flex flex-col gap-3">
		{#each [0, 1, 2] as i (i)}<Skeleton class="h-7 w-full" />{/each}
	</div>
{:else}
	<Skeleton class="h-[250px] w-full" />
{/if}
