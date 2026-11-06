<script lang="ts">
	import { resolve } from '$app/paths';
	import ArrowRightIcon from '@lucide/svelte/icons/arrow-right';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { formatAgo } from '#lib/format.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import type { Tone } from '#lib/design/tone.js';
	import type { Finding, Severity } from './types.js';

	let { findings }: { findings: Finding[] } = $props();

	const tone: Record<Severity, Tone> = { ok: 'ok', info: 'info', warn: 'warn', error: 'err' };
	const label: Record<Severity, string> = {
		ok: 'In Ordnung',
		info: 'Hinweis',
		warn: 'Warnung',
		error: 'Fehler'
	};
</script>

<ul class="divide-y">
	{#each findings as f (f.id)}
		<li
			class="flex flex-col gap-1.5 py-3.5 first:pt-0 last:pb-0 sm:flex-row sm:items-start sm:gap-4"
		>
			<div class="sm:w-28 sm:shrink-0 sm:pt-0.5">
				<StatusBadge tone={tone[f.severity]} label={label[f.severity]} />
			</div>
			<div class="min-w-0 flex-1">
				<p class="text-sm font-medium">{f.title}</p>
				<p class="text-muted-foreground text-[13px] leading-5">{f.detail}</p>
				<p class="text-muted-foreground mt-0.5 text-[12px]">
					seit {formatAgo(f.since, ctx.now).replace('vor ', '')}
				</p>
			</div>
			{#if f.href}
				<a
					href={resolve(f.href as '/')}
					class="text-primary-ink hover:bg-primary-soft -mx-2 inline-flex h-9 items-center gap-1 self-start rounded-md px-2 text-[13px] font-medium sm:mx-0"
				>
					Ansehen <ArrowRightIcon class="size-3.5" aria-hidden="true" />
				</a>
			{/if}
		</li>
	{/each}
</ul>
