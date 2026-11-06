<script lang="ts">
	import type { Component, Snippet } from 'svelte';
	import InboxIcon from '@lucide/svelte/icons/inbox';
	let {
		title,
		reason,
		icon: Icon = InboxIcon,
		actions,
		compact = false
	}: {
		title: string;
		/** Grund und was zu tun ist. */
		reason?: string;
		icon?: Component;
		actions?: Snippet;
		compact?: boolean;
	} = $props();
</script>

<div
	class="flex flex-col items-center justify-center text-center {compact
		? 'gap-1.5 py-6'
		: 'gap-2 py-10'}"
>
	<span
		class="bg-muted text-muted-foreground mb-1 inline-flex size-10 items-center justify-center rounded-full"
	>
		<Icon class="size-5" aria-hidden="true" />
	</span>
	<p class="text-sm font-medium">{title}</p>
	{#if reason}<p class="text-muted-foreground max-w-sm text-[13px]">{reason}</p>{/if}
	{#if actions}<div class="mt-2">{@render actions()}</div>{/if}
</div>
