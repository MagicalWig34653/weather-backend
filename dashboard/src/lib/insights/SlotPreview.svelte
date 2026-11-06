<script lang="ts">
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import ChevronRightIcon from '@lucide/svelte/icons/chevron-right';
	import ChevronsRightIcon from '@lucide/svelte/icons/chevrons-right';
	import ImageOffIcon from '@lucide/svelte/icons/image-off';
	import { Button } from '#lib/components/ui/button/index.js';
	import Skeleton from '#lib/design/Skeleton.svelte';
	import { formatBytes, formatDateTime } from '#lib/format.js';
	import { insights } from './api.js';
	import { layerName } from './text.js';
	import type { CacheSlot } from './types.js';

	/** `slots` aufsteigend nach Zeit (aeltester zuerst). */
	let {
		layer,
		slots,
		index = $bindable(0)
	}: { layer: string; slots: CacheSlot[]; index: number } = $props();

	const slot = $derived(slots[index]);
	const src = $derived(slot ? insights.cachePreviewUrl(layer, slot.slot, slot.run) : '');
	let state = $state<'loading' | 'ok' | 'error'>('loading');
	// Neues Bild: zurueck in den Ladezustand (Browser feuert load/error je Bild).
	$effect(() => {
		void src;
		state = 'loading';
	});

	const alt = $derived(
		slot ? `${layerName(layer)}, Bild vom ${formatDateTime(slot.slot)}` : 'Kein Bild gewählt'
	);

	function step(d: number): void {
		index = Math.min(slots.length - 1, Math.max(0, index + d));
	}
	function onkey(e: KeyboardEvent): void {
		if (e.key === 'ArrowLeft') {
			e.preventDefault();
			step(-1);
		} else if (e.key === 'ArrowRight') {
			e.preventDefault();
			step(1);
		} else if (e.key === 'Home') {
			e.preventDefault();
			index = 0;
		} else if (e.key === 'End') {
			e.preventDefault();
			index = slots.length - 1;
		}
	}
</script>

<div class="grid gap-5 lg:grid-cols-[minmax(0,26rem)_minmax(0,1fr)]">
	<figure class="m-0">
		<!-- Rahmen mit festem Seitenverhaeltnis: das Layout springt beim Laden nicht. -->
		<div
			class="bg-muted relative mx-auto aspect-square w-full max-w-[26rem] overflow-hidden rounded-xl border shadow-sm"
		>
			{#if slot}
				<img
					{src}
					{alt}
					width="416"
					height="416"
					decoding="async"
					class="absolute inset-0 size-full object-contain transition-opacity {state === 'ok'
						? 'opacity-100'
						: 'opacity-0'}"
					onload={() => (state = 'ok')}
					onerror={() => (state = 'error')}
				/>
			{/if}
			{#if state === 'loading' && slot}
				<div class="absolute inset-0" aria-hidden="true"><Skeleton class="size-full" /></div>
				<span class="sr-only" role="status">Bild wird geladen …</span>
			{/if}
			{#if state === 'error' || !slot}
				<div
					class="text-muted-foreground absolute inset-0 flex flex-col items-center justify-center gap-2 p-6 text-center text-[13px]"
					role={slot ? 'alert' : undefined}
				>
					<ImageOffIcon class="size-8" aria-hidden="true" />
					{#if slot}
						Das Bild konnte nicht geladen werden (Sitzung, Format oder Größe). Der Slot ist in der
						Datenbank vermerkt.
					{:else}
						Kein Slot gewählt.
					{/if}
				</div>
			{/if}
		</div>
		<figcaption class="text-muted-foreground mt-2 text-center text-[12px]">
			{#if slot}{alt}{/if}
		</figcaption>
	</figure>

	<div class="min-w-0 space-y-4">
		{#if slot}
			<div>
				<label for="slot-range" class="mb-1.5 block text-[13px] font-semibold">
					Zeitpunkt wählen
					<span class="text-muted-foreground font-normal">
						({index + 1} von {slots.length}, links ältester Slot)</span
					>
				</label>
				<input
					id="slot-range"
					type="range"
					min="0"
					max={Math.max(0, slots.length - 1)}
					step="1"
					bind:value={index}
					onkeydown={onkey}
					aria-valuetext={formatDateTime(slot.slot)}
					class="accent-primary h-8 w-full cursor-pointer"
				/>
				<div class="mt-1 flex items-center justify-between gap-2">
					<Button
						variant="outline"
						size="sm"
						onclick={() => step(-1)}
						disabled={index === 0}
						aria-label="Vorheriger Slot"
					>
						<ChevronLeftIcon aria-hidden="true" />Zurück
					</Button>
					<Button
						variant="outline"
						size="sm"
						onclick={() => (index = slots.length - 1)}
						disabled={index === slots.length - 1}
					>
						<ChevronsRightIcon aria-hidden="true" />Neuester
					</Button>
					<Button
						variant="outline"
						size="sm"
						onclick={() => step(1)}
						disabled={index === slots.length - 1}
						aria-label="Nächster Slot"
					>
						Weiter<ChevronRightIcon aria-hidden="true" />
					</Button>
				</div>
			</div>
			<dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px]">
				<div>
					<dt class="text-muted-foreground">Bildzeit (Slot)</dt>
					<dd class="num font-medium">
						<time datetime={slot.slot}>{formatDateTime(slot.slot)}</time>
					</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Lauf (Nominalzeit)</dt>
					<dd class="num font-medium">
						<time datetime={slot.run}>{formatDateTime(slot.run)}</time>
					</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Nummer im Lauf</dt>
					<dd class="num font-medium">{slot.index}{slot.index === 0 ? ' (Analyse)' : ''}</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Größe und Format</dt>
					<dd class="num font-medium">{formatBytes(slot.bytes)}, {slot.contentType}</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Veröffentlicht</dt>
					<dd class="num font-medium">
						{#if slot.published && slot.publishedAt}<time datetime={slot.publishedAt}
								>{formatDateTime(slot.publishedAt)}</time
							>{:else}nein{/if}
					</dd>
				</div>
			</dl>
		{/if}
	</div>
</div>
