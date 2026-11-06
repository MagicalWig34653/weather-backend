<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { onMount } from 'svelte';
	import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
	import PlayIcon from '@lucide/svelte/icons/circle-play';
	import PauseIcon from '@lucide/svelte/icons/circle-pause';
	import MonitorIcon from '@lucide/svelte/icons/monitor';
	import MoonIcon from '@lucide/svelte/icons/moon';
	import SunIcon from '@lucide/svelte/icons/sun';
	import { formatTime } from '#lib/format.js';
	import { theme } from '#lib/theme.svelte.js';
	import { ctx, parseRange, RANGES, REFRESH_MS } from '../context.svelte.js';
	import Segmented from '../Segmented.svelte';
	import Toaster from '../Toaster.svelte';
	import Logo from './Logo.svelte';
	import MobileTabs from './MobileTabs.svelte';
	import SessionMenu from './SessionMenu.svelte';
	import { activeItem, NAV } from './nav.js';

	let { children }: { children: Snippet } = $props();

	const base = resolve('/').replace(/\/$/, '');
	const path = $derived(page.url.pathname.replace(base, '') || '/');
	const current = $derived(activeItem(path));

	// Der Zeitbereich lebt in der URL (?range=7d) und wird hier in den Anzeigezustand uebernommen.
	$effect(() => {
		ctx.range = parseRange(page.url.searchParams.get('range'));
	});

	function setRange(v: string): void {
		const url = new URL(page.url.href);
		if (v === '24h') url.searchParams.delete('range');
		else url.searchParams.set('range', v);
		void goto(url.pathname + url.search, { replace: true, reset: false });
	}

	/** Zielpfad inklusive Zeitbereich, damit er beim Seitenwechsel erhalten bleibt. */
	function hrefFor(item: { href: string; range: boolean }): string {
		const to = resolve(item.href as '/');
		return item.range && ctx.range !== '24h' ? `${to}?range=${ctx.range}` : to;
	}

	onMount(() => {
		const clock = setInterval(() => (ctx.now = Date.now()), 15_000);
		return () => clearInterval(clock);
	});
	$effect(() => {
		if (!ctx.auto) return;
		const id = setInterval(() => ctx.refresh(), REFRESH_MS);
		return () => clearInterval(id);
	});

	$effect(() => {
		document.title = `${current?.title ?? 'Dashboard'} · Showers Betrieb`;
	});

	const themeLabel = $derived(
		theme.choice === 'system' ? 'Automatisch' : theme.choice === 'light' ? 'Hell' : 'Dunkel'
	);
	const rangeOptions = RANGES.map((r) => ({ value: r.value, label: r.label, title: r.title }));
	const rangeTitle = $derived(RANGES.find((r) => r.value === ctx.range)?.title ?? '');
</script>

<a
	href="#inhalt"
	class="bg-primary text-primary-foreground sr-only z-[70] rounded-md px-3 py-2 focus:not-sr-only focus:fixed focus:top-2 focus:left-2"
>
	Zum Inhalt springen
</a>

<!-- Seitenleiste (ab 768 px) -->
<aside class="bg-sidebar fixed inset-y-0 left-0 z-40 hidden w-60 flex-col border-r nav:flex">
	<a href={resolve('/')} class="px-5 pt-5 pb-4" aria-label="Showers Betrieb, Übersicht">
		<Logo />
	</a>
	<nav aria-label="Hauptnavigation" class="min-h-0 flex-1 overflow-y-auto px-3 pb-4">
		{#each NAV as group (group.label)}
			<div class="mt-4 first:mt-0">
				<p
					class="text-muted-foreground px-3 pb-1.5 text-[11px] font-semibold tracking-wider uppercase"
				>
					{group.label}
				</p>
				<ul class="flex flex-col gap-0.5">
					{#each group.items as item (item.href)}
						{@const on = current?.href === item.href}
						{@const Icon = item.icon}
						<li>
							<a
								href={hrefFor(item)}
								aria-current={on ? 'page' : undefined}
								class="text-muted-foreground hover:bg-muted hover:text-foreground aria-[current=page]:bg-primary-soft aria-[current=page]:text-primary-ink flex h-9 items-center gap-3 rounded-lg px-3 text-[13px] font-medium transition-colors"
							>
								<Icon class="size-[17px] shrink-0" aria-hidden="true" />
								<span class="truncate">{item.label}</span>
							</a>
						</li>
					{/each}
				</ul>
			</div>
		{/each}
	</nav>
	<div class="text-muted-foreground flex items-center gap-2 border-t px-5 py-3 text-[12px]">
		<span class="bg-ok-fill size-2 rounded-full" aria-hidden="true"></span>
		<span>{__MOCK__ ? 'Mock-Daten' : 'Verbunden'}</span>
	</div>
</aside>

<div class="nav:pl-60">
	<header class="glass-header sticky top-0 z-30 border-b">
		<div class="mx-auto flex h-14 max-w-[1280px] items-center gap-3 px-4 nav:px-6">
			<a href={resolve('/')} class="nav:hidden" aria-label="Übersicht"><Logo /></a>
			<p
				class="text-muted-foreground hidden min-w-0 truncate text-[13px] nav:block"
				aria-hidden="true"
			>
				Showers Betrieb <span class="mx-1.5">/</span>
				<span class="text-foreground font-medium">{current?.title}</span>
			</p>
			<div class="ml-auto flex items-center gap-1">
				{#if current?.range}
					<div class="mr-2 hidden sm:block">
						<Segmented
							label="Zeitbereich, {rangeTitle}"
							options={rangeOptions}
							value={ctx.range}
							onchange={setRange}
						/>
					</div>
				{/if}
				{#if ctx.updatedAt}
					<span class="num text-muted-foreground mr-1 hidden text-[12px] xl:inline">
						Stand <time datetime={new Date(ctx.updatedAt).toISOString()}
							>{formatTime(new Date(ctx.updatedAt).toISOString())}</time
						>
					</span>
				{/if}
				<button
					type="button"
					onclick={() => ctx.refresh()}
					aria-label="Aktualisieren"
					title="Aktualisieren"
					class="text-muted-foreground hover:bg-muted hover:text-foreground inline-flex size-9 items-center justify-center rounded-lg"
				>
					<RefreshCwIcon class="size-4" aria-hidden="true" />
				</button>
				<button
					type="button"
					aria-pressed={ctx.auto}
					onclick={() => (ctx.auto = !ctx.auto)}
					title="Automatisch alle {REFRESH_MS / 1000} s aktualisieren"
					aria-label="Automatisch aktualisieren (alle {REFRESH_MS / 1000} Sekunden)"
					class="hover:bg-muted inline-flex size-9 items-center justify-center rounded-lg {ctx.auto
						? 'text-primary-ink bg-primary-soft'
						: 'text-muted-foreground hover:text-foreground'}"
				>
					{#if ctx.auto}<PauseIcon class="size-4" aria-hidden="true" />{:else}<PlayIcon
							class="size-4"
							aria-hidden="true"
						/>{/if}
				</button>
				<button
					type="button"
					onclick={() => theme.cycle()}
					aria-label="Farbschema wechseln, aktuell: {themeLabel}"
					title="Farbschema: {themeLabel}"
					class="text-muted-foreground hover:bg-muted hover:text-foreground hidden size-9 items-center justify-center rounded-lg sm:inline-flex"
				>
					{#if theme.choice === 'dark'}<MoonIcon
							class="size-4"
							aria-hidden="true"
						/>{:else if theme.choice === 'light'}<SunIcon
							class="size-4"
							aria-hidden="true"
						/>{:else}<MonitorIcon class="size-4" aria-hidden="true" />{/if}
				</button>
				<SessionMenu />
			</div>
		</div>
		{#if current?.range}
			<div class="border-t px-4 py-2 sm:hidden">
				<Segmented
					label="Zeitbereich, {rangeTitle}"
					options={rangeOptions}
					value={ctx.range}
					onchange={setRange}
				/>
			</div>
		{/if}
	</header>

	{#if __MOCK__}
		<p class="bg-warn-soft text-warn px-4 py-1 text-center text-xs">
			Mock-Modus: erfundene Platzhalterdaten, kein Backend verbunden.
		</p>
	{/if}

	<main
		id="inhalt"
		tabindex="-1"
		class="mx-auto max-w-[1280px] px-4 pt-6 pb-28 outline-none nav:px-6 nav:pt-8 nav:pb-12"
	>
		<div class="fade-in space-y-6">
			{@render children()}
		</div>
	</main>
</div>

<MobileTabs {hrefFor} activeHref={current?.href} />
<Toaster />
