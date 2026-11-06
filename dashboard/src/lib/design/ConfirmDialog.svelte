<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as Dialog from '#lib/components/ui/dialog/index.js';
	import { Button } from '#lib/components/ui/button/index.js';

	let {
		open = $bindable(false),
		title,
		description,
		confirmLabel = 'Bestätigen',
		destructive = false,
		busy = false,
		onconfirm,
		children
	}: {
		open?: boolean;
		title: string;
		/** Nennt die konkrete Folge der Aktion. */
		description: string;
		confirmLabel?: string;
		destructive?: boolean;
		busy?: boolean;
		onconfirm: () => void | Promise<void>;
		children?: Snippet;
	} = $props();
</script>

<Dialog.Root bind:open>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>{title}</Dialog.Title>
			<Dialog.Description>{description}</Dialog.Description>
		</Dialog.Header>
		{@render children?.()}
		<Dialog.Footer>
			<Button variant="outline" onclick={() => (open = false)} disabled={busy}>Abbrechen</Button>
			<Button
				variant={destructive ? 'destructive' : 'default'}
				onclick={() => onconfirm()}
				disabled={busy}
			>
				{busy ? 'Läuft …' : confirmLabel}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
