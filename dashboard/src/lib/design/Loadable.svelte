<script lang="ts" generics="T">
	import type { Snippet } from 'svelte';
	import type { Resource } from '#lib/resource.svelte.js';
	import ErrorState from './ErrorState.svelte';
	import StaleNotice from './StaleNotice.svelte';
	import { ctx } from './context.svelte.js';

	/**
	 * Einheitliche Zustaende je Widget: Laden (Skeleton gleicher Groesse), Fehler (nur dieses Widget),
	 * veraltet (Daten da, letzte Aktualisierung fehlgeschlagen oder zu alt), Inhalt.
	 */
	let {
		res,
		skeleton,
		children,
		compact = false
	}: {
		res: Resource<T>;
		skeleton: Snippet;
		children: Snippet<[T]>;
		compact?: boolean;
	} = $props();

	const stale = $derived(res.data !== null && (res.error !== null || ctx.stale(res.loadedAt)));
</script>

{#if res.data === null && res.error === null}
	<div aria-busy="true" aria-live="polite">
		<span class="sr-only">Lade …</span>{@render skeleton()}
	</div>
{:else if res.data === null}
	<ErrorState message={res.error ?? ''} onretry={() => void res.load()} {compact} />
{:else}
	{#if stale}
		<div class="mb-3"><StaleNotice since={res.loadedAt} error={res.error} /></div>
	{/if}
	<div class="space-y-6 transition-opacity {res.loading ? 'opacity-70' : ''}">
		{@render children(res.data)}
	</div>
{/if}
