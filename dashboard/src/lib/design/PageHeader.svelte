<script lang="ts">
	import type { Snippet } from 'svelte';
	let { title, description, actions }: { title: string; description?: string; actions?: Snippet } =
		$props();
</script>

<div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3">
	<div class="min-w-0">
		<h1 class="text-[22px] leading-8 font-semibold tracking-tight sm:text-2xl">{title}</h1>
		{#if description}<p class="text-muted-foreground mt-0.5 max-w-2xl text-sm">
				{description}
			</p>{/if}
	</div>
	{#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</div>
