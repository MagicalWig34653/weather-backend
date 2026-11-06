<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { session } from '#lib/session.svelte.js';
	import { theme } from '#lib/theme.svelte.js';
	import AuthPanel from '#lib/components/auth-panel.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import Shell from '#lib/design/shell/Shell.svelte';
	import Toaster from '#lib/design/Toaster.svelte';

	let { children } = $props();

	onMount(() => {
		theme.init();
		void session.refresh();
	});
</script>

<svelte:head>
	<title>Showers Betrieb</title>
</svelte:head>

{#if session.loading}
	<div class="text-muted-foreground flex min-h-dvh items-center justify-center" role="status">
		Lade …
	</div>
{:else if session.state === null}
	<div
		class="mx-auto flex min-h-dvh max-w-md flex-col items-center justify-center gap-4 p-4 text-center"
	>
		<p role="alert" class="text-destructive">
			{session.error ?? 'Der Server ist nicht erreichbar.'}
		</p>
		<Button variant="outline" onclick={() => session.refresh()}>Erneut versuchen</Button>
	</div>
	<Toaster />
{:else if session.state.state !== 'authenticated'}
	<AuthPanel mode={session.state} />
{:else}
	<Shell>{@render children()}</Shell>
{/if}
