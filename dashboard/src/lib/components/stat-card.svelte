<script lang="ts">
	import * as Card from '#lib/components/ui/card/index.js';
	import type { Snippet } from 'svelte';

	let {
		title,
		value,
		hint,
		children
	}: { title: string; value: string; hint?: string; children?: Snippet } = $props();
</script>

<Card.Root>
	<Card.Header>
		<Card.Description>{title}</Card.Description>
		<Card.Title class="text-3xl font-semibold tabular-nums">{value}</Card.Title>
	</Card.Header>
	{#if hint || children}
		<Card.Content class="text-muted-foreground text-sm">
			{hint}
			{@render children?.()}
		</Card.Content>
	{/if}
</Card.Root>
