<script lang="ts">
	import { Popover } from 'bits-ui';
	import InfoIcon from '@lucide/svelte/icons/info';
	let { label, text }: { label: string; text: string } = $props();
</script>

<Popover.Root>
	<Popover.Trigger
		aria-label={label}
		class="text-muted-foreground hover:text-foreground hover:bg-muted -m-1 inline-flex size-8 items-center justify-center rounded-md transition-colors"
	>
		<InfoIcon class="size-4" aria-hidden="true" />
	</Popover.Trigger>
	<Popover.Portal>
		<Popover.Content
			sideOffset={6}
			collisionPadding={12}
			class="bg-popover text-popover-foreground shadow-pop fade-in z-50 max-w-72 rounded-lg border p-3 text-[13px] leading-5"
		>
			{text}
		</Popover.Content>
	</Popover.Portal>
</Popover.Root>
