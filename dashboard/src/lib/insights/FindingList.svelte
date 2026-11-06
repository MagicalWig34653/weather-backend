<script lang="ts">
	import { resolve } from '$app/paths';
	import ArrowRightIcon from '@lucide/svelte/icons/arrow-right';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { formatAgo } from '#lib/format.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import { findingHref, findingText, levelLabel, levelTone } from './text.js';
	import type { Finding } from './types.js';

	let { findings }: { findings: Finding[] } = $props();
</script>

<ul class="divide-y">
	{#each findings as f (f.code + (f.subject ?? ''))}
		{@const text = findingText(f)}
		<li
			class="flex flex-col gap-1.5 py-3.5 first:pt-0 last:pb-0 sm:flex-row sm:items-start sm:gap-4"
		>
			<div class="sm:w-28 sm:shrink-0 sm:pt-0.5">
				<StatusBadge tone={levelTone(f.level)} label={levelLabel[f.level]} />
			</div>
			<div class="min-w-0 flex-1">
				<p class="text-sm font-medium">{text.title}</p>
				<p class="text-muted-foreground text-[13px] leading-5">{text.detail}</p>
				{#if f.since}
					<p class="text-muted-foreground mt-0.5 text-[12px]">
						seit {formatAgo(f.since, ctx.now).replace('vor ', '')}
					</p>
				{/if}
			</div>
			<a
				href={resolve(findingHref(f) as '/')}
				class="text-primary-ink hover:bg-primary-soft -mx-2 inline-flex h-9 items-center gap-1 self-start rounded-md px-2 text-[13px] font-medium sm:mx-0"
			>
				Ansehen <ArrowRightIcon class="size-3.5" aria-hidden="true" />
			</a>
		</li>
	{/each}
</ul>
