<script lang="ts">
	import './layout.css';
	import favicon from '#lib/assets/favicon.svg';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import { MOCK } from '#lib/client.js';
	import { session } from '#lib/session.svelte.js';
	import { theme } from '#lib/theme.svelte.js';
	import AuthPanel from '#lib/components/auth-panel.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import MonitorIcon from '@lucide/svelte/icons/monitor';
	import MoonIcon from '@lucide/svelte/icons/moon';
	import SunIcon from '@lucide/svelte/icons/sun';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import CloudRainIcon from '@lucide/svelte/icons/cloud-rain';

	let { children } = $props();

	onMount(() => {
		theme.init();
		void session.refresh();
	});

	const nav = [
		{ href: '/', label: 'Übersicht' },
		{ href: '/traffic', label: 'Traffic' },
		{ href: '/konfiguration', label: 'Konfiguration' },
		{ href: '/protokoll', label: 'Änderungsprotokoll' }
	] as const;

	const themeLabel = $derived(
		theme.choice === 'system' ? 'Automatisch' : theme.choice === 'light' ? 'Hell' : 'Dunkel'
	);

	function active(href: string): boolean {
		const path = page.url.pathname.replace(/\/$/, '') || '/';
		const target = resolve(href as '/').replace(/\/$/, '') || '/';
		return target === resolve('/').replace(/\/$/, '') ? path === target : path.startsWith(target);
	}
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>Showers Dashboard</title>
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
{:else if session.state.state !== 'authenticated'}
	<AuthPanel mode={session.state} />
{:else}
	<a
		href="#inhalt"
		class="bg-primary text-primary-foreground sr-only z-50 rounded-md px-3 py-2 focus:not-sr-only focus:fixed focus:top-2 focus:left-2"
		>Zum Inhalt springen</a
	>
	<header class="bg-card/80 sticky top-0 z-40 border-b backdrop-blur">
		<div class="mx-auto flex max-w-6xl flex-wrap items-center gap-x-6 gap-y-2 px-4 py-2">
			<div class="flex items-center gap-2 font-semibold">
				<CloudRainIcon class="text-primary size-5" aria-hidden="true" />
				Showers Dashboard
			</div>
			<nav
				aria-label="Hauptnavigation"
				class="order-3 -mx-1 flex w-full gap-1 overflow-x-auto sm:order-none sm:mx-0 sm:w-auto"
			>
				{#each nav as item (item.href)}
					<a
						href={resolve(item.href)}
						aria-current={active(item.href) ? 'page' : undefined}
						class="text-muted-foreground hover:text-foreground aria-[current=page]:bg-accent aria-[current=page]:text-foreground focus-visible:ring-ring/50 rounded-md px-3 py-1.5 text-sm font-medium whitespace-nowrap outline-none focus-visible:ring-3"
						>{item.label}</a
					>
				{/each}
			</nav>
			<div class="ml-auto flex items-center gap-1">
				<Button
					variant="ghost"
					size="sm"
					onclick={() => theme.cycle()}
					aria-label="Farbschema wechseln, aktuell: {themeLabel}"
					title="Farbschema: {themeLabel}"
				>
					{#if theme.choice === 'dark'}<MoonIcon
							aria-hidden="true"
						/>{:else if theme.choice === 'light'}<SunIcon aria-hidden="true" />{:else}<MonitorIcon
							aria-hidden="true"
						/>{/if}
					<span class="hidden sm:inline">{themeLabel}</span>
				</Button>
				<Button variant="ghost" size="sm" onclick={() => session.logout()}>
					<LogOutIcon aria-hidden="true" />
					Abmelden
				</Button>
			</div>
		</div>
	</header>
	{#if MOCK}
		<div class="bg-warning text-warning-foreground px-4 py-1 text-center text-xs">
			Mock-Modus: erfundene Platzhalterdaten, kein Backend verbunden.
		</div>
	{/if}
	<main id="inhalt" class="mx-auto max-w-6xl space-y-6 p-4 py-6 sm:py-8">
		{@render children()}
	</main>
{/if}
