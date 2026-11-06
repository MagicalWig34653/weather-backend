<script lang="ts">
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';
	import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
	import { Button } from '#lib/components/ui/button/index.js';
	let {
		message,
		onretry,
		compact = false
	}: { message: string; onretry?: () => void; compact?: boolean } = $props();
</script>

<div
	role="alert"
	class="flex flex-col items-center justify-center gap-2 text-center {compact ? 'py-6' : 'py-10'}"
>
	<span
		class="bg-destructive-soft text-destructive mb-1 inline-flex size-10 items-center justify-center rounded-full"
	>
		<TriangleAlertIcon class="size-5" aria-hidden="true" />
	</span>
	<p class="text-sm font-medium">Daten konnten nicht geladen werden</p>
	<p class="text-muted-foreground max-w-sm text-[13px]">{message}</p>
	{#if onretry}
		<Button variant="outline" size="sm" class="mt-2" onclick={onretry}>
			<RefreshCwIcon aria-hidden="true" /> Erneut versuchen
		</Button>
	{/if}
</div>
