<script lang="ts">
	import type { Snippet } from 'svelte';
	import InfoPopover from './InfoPopover.svelte';
	let {
		title,
		description,
		info,
		actions,
		children,
		class: className = '',
		flush = false,
		headingLevel = 2
	}: {
		title?: string;
		description?: string;
		/** Erklaertext: erscheint als aufklappbares "Was zeigt das?". */
		info?: string;
		actions?: Snippet;
		children?: Snippet;
		class?: string;
		/** Inhalt ohne Innenabstand (Tabellen). */
		flush?: boolean;
		headingLevel?: 2 | 3;
	} = $props();
</script>

<section
	class="bg-card text-card-foreground shadow-card min-w-0 rounded-xl border {className}"
	aria-label={title}
>
	{#if title || actions}
		<header class="flex items-start justify-between gap-3 px-4 pt-4 sm:px-5 {flush ? 'pb-3' : ''}">
			<div class="min-w-0">
				{#if title}
					<div class="flex items-center gap-1.5">
						<svelte:element
							this={`h${headingLevel}`}
							class="text-[15px] leading-6 font-semibold tracking-tight"
						>
							{title}
						</svelte:element>
						{#if info}<InfoPopover label="Was zeigt „{title}“?" text={info} />{/if}
					</div>
				{/if}
				{#if description}
					<p class="text-muted-foreground mt-0.5 text-[13px] leading-5">{description}</p>
				{/if}
			</div>
			{#if actions}<div class="flex shrink-0 items-center gap-1.5">{@render actions()}</div>{/if}
		</header>
	{/if}
	<div class={flush ? 'pt-0 pb-1.5' : 'px-4 pt-3 pb-4 sm:px-5 sm:pb-5'}>
		{@render children?.()}
	</div>
</section>
