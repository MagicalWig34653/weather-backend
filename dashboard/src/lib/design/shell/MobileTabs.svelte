<script lang="ts">
	import { Popover } from 'bits-ui';
	import EllipsisIcon from '@lucide/svelte/icons/ellipsis';
	import { ALL_ITEMS } from './nav.js';
	import ThemeSwitch from './ThemeSwitch.svelte';

	let {
		hrefFor,
		activeHref
	}: { hrefFor: (i: { href: string; range: boolean }) => string; activeHref?: string } = $props();

	const tabs = ALL_ITEMS.filter((i) => i.tab);
	const more = ALL_ITEMS.filter((i) => !i.tab);
	const moreActive = $derived(more.some((i) => i.href === activeHref));
	let open = $state(false);

	const cell =
		'text-muted-foreground aria-[current=page]:text-primary-ink flex min-h-14 flex-1 flex-col items-center justify-center gap-0.5 rounded-lg text-[11px] font-medium';
</script>

<!-- Telefon: untere Tab-Leiste mit vier Zielen und "Mehr" (Ziele mindestens 44 px) -->
<nav
	aria-label="Hauptnavigation"
	class="bg-card/95 fixed inset-x-0 bottom-0 z-40 border-t pb-[env(safe-area-inset-bottom)] backdrop-blur nav:hidden"
>
	<div class="mx-auto flex max-w-lg items-stretch px-2 pt-1">
		{#each tabs as item (item.href)}
			{@const Icon = item.icon}
			<a
				href={hrefFor(item)}
				aria-current={activeHref === item.href ? 'page' : undefined}
				class={cell}
			>
				<span
					class="inline-flex h-7 w-12 items-center justify-center rounded-full transition-colors {activeHref ===
					item.href
						? 'bg-primary-soft'
						: ''}"
				>
					<Icon class="size-5" aria-hidden="true" />
				</span>
				{item.label}
			</a>
		{/each}
		<Popover.Root bind:open>
			<Popover.Trigger aria-current={moreActive ? 'page' : undefined} class={cell}>
				<span
					class="inline-flex h-7 w-12 items-center justify-center rounded-full {moreActive
						? 'bg-primary-soft'
						: ''}"
				>
					<EllipsisIcon class="size-5" aria-hidden="true" />
				</span>
				Mehr
			</Popover.Trigger>
			<Popover.Portal>
				<Popover.Content
					side="top"
					align="end"
					sideOffset={10}
					collisionPadding={12}
					class="bg-popover text-popover-foreground shadow-pop fade-in z-50 w-60 rounded-xl border p-2"
				>
					<ul class="flex flex-col">
						{#each more as item (item.href)}
							{@const Icon = item.icon}
							<li>
								<a
									href={hrefFor(item)}
									onclick={() => (open = false)}
									aria-current={activeHref === item.href ? 'page' : undefined}
									class="hover:bg-muted aria-[current=page]:text-primary-ink flex min-h-11 items-center gap-3 rounded-lg px-3 text-sm font-medium"
								>
									<Icon class="size-[18px]" aria-hidden="true" />
									{item.title}
								</a>
							</li>
						{/each}
					</ul>
					<div class="mt-1 flex items-center justify-between border-t px-3 pt-3 pb-1">
						<span class="text-[13px] font-medium">Darstellung</span>
						<ThemeSwitch />
					</div>
				</Popover.Content>
			</Popover.Portal>
		</Popover.Root>
	</div>
</nav>
