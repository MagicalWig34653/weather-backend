<script lang="ts">
	import ClockAlertIcon from '@lucide/svelte/icons/clock-alert';
	import { formatDuration, formatTime } from '#lib/format.js';
	let {
		since,
		error,
		serverStaleSeconds = null,
		onretry
	}: {
		since: number | null;
		error?: string | null;
		serverStaleSeconds?: number | null;
		onretry?: () => void;
	} = $props();
</script>

<p
	role="status"
	class="bg-warn-soft text-warn flex flex-wrap items-center gap-x-2 gap-y-1 rounded-lg px-3 py-2 text-[13px]"
>
	<ClockAlertIcon class="size-4 shrink-0" aria-hidden="true" />
	<span class="min-w-0 flex-1">
		Veraltet{since ? `: Stand ${formatTime(new Date(since).toISOString())}` : ''}.
		{#if error}
			Die Aktualisierung ist wiederholt fehlgeschlagen. {error} Der nächste Versuch erfolgt automatisch.
		{:else if serverStaleSeconds !== null}
			Die Berechnung auf dem Server ist fehlgeschlagen; angezeigt wird die letzte gute Antwort ({formatDuration(
				serverStaleSeconds
			)} alt).
		{:else}
			Es sind länger keine neuen Daten eingetroffen.
		{/if}
	</span>
	{#if onretry}
		<button type="button" class="font-medium underline underline-offset-2" onclick={onretry}>
			Jetzt erneut laden
		</button>
	{/if}
</p>
