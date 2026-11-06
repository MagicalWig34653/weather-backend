<script lang="ts">
	import XIcon from '@lucide/svelte/icons/x';
	import { toast } from './toast.svelte.js';
	import { toneIcon, toneText } from './tone.js';
</script>

<!-- Eine einzige Live-Region; Fehler werden unterbrechend (assertive) angesagt. -->
<div
	class="pointer-events-none fixed inset-x-0 bottom-20 z-[60] flex flex-col items-center gap-2 px-4 nav:inset-x-auto nav:right-6 nav:bottom-6 nav:items-end"
	role="region"
	aria-label="Meldungen"
>
	{#each toast.items as t (t.id)}
		{@const Icon = toneIcon[t.tone]}
		<div
			role={t.tone === 'err' ? 'alert' : 'status'}
			class="bg-popover text-popover-foreground shadow-pop fade-in pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded-xl border p-3.5"
		>
			<Icon class="mt-0.5 size-4.5 shrink-0 {toneText[t.tone]}" aria-hidden="true" />
			<div class="min-w-0 flex-1">
				<p class="text-sm leading-5 font-medium">{t.title}</p>
				{#if t.detail}<p class="text-muted-foreground mt-0.5 text-[13px] whitespace-pre-line">
						{t.detail}
					</p>{/if}
			</div>
			<button
				type="button"
				onclick={() => toast.dismiss(t.id)}
				aria-label="Meldung schließen"
				class="text-muted-foreground hover:bg-muted hover:text-foreground -m-1.5 inline-flex size-8 items-center justify-center rounded-md"
			>
				<XIcon class="size-4" aria-hidden="true" />
			</button>
		</div>
	{/each}
</div>
