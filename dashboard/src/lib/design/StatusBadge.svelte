<script lang="ts">
	import type { Snippet } from 'svelte';
	import { toneIcon, toneSoft, type Tone } from './tone.js';
	let {
		tone = 'neutral',
		label,
		children,
		icon = true
	}: { tone?: Tone; label?: string; children?: Snippet; icon?: boolean } = $props();
	const Icon = $derived(toneIcon[tone]);
</script>

<span
	class="inline-flex h-6 items-center gap-1 rounded-full px-2.5 text-xs font-medium whitespace-nowrap {toneSoft[
		tone
	]}"
>
	{#if icon}<Icon class="size-3.5" aria-hidden="true" />{/if}
	{#if children}{@render children()}{:else}{label}{/if}
</span>
