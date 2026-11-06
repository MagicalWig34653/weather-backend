<script lang="ts">
	import ClockAlertIcon from '@lucide/svelte/icons/clock-alert';
	import { formatTime } from '#lib/format.js';
	let { since, error }: { since: number | null; error?: string | null } = $props();
</script>

<p
	role="status"
	class="bg-warn-soft text-warn flex items-center gap-2 rounded-lg px-3 py-2 text-[13px]"
>
	<ClockAlertIcon class="size-4 shrink-0" aria-hidden="true" />
	<span>
		Veraltet{since ? `: Stand ${formatTime(new Date(since).toISOString())}` : ''}.
		{error ?? 'Die Aktualisierung ist fehlgeschlagen.'}
	</span>
</p>
