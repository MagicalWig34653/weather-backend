<script lang="ts">
	// Die Vorschau wird nur im Dev-/Mock-Build geladen; im Produktionsbuild entfaellt der Import samt Chunk.
	const preview = __MOCK__ || import.meta.env.DEV ? import('./Preview.svelte') : null;
</script>

{#if preview}
	{#await preview then m}
		<m.default />
	{/await}
{/if}
