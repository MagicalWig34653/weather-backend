<script lang="ts">
	import HourglassIcon from '@lucide/svelte/icons/hourglass';
	let { what = 'Diese Zähler' }: { what?: string } = $props();
</script>

<div class="text-muted-foreground flex items-start gap-2.5 py-2 text-[13px]">
	<HourglassIcon class="mt-0.5 size-4 shrink-0" aria-hidden="true" />
	<p>
		<span class="text-foreground font-medium">Noch nicht erhoben.</span>
		{what} stehen zur Verfügung, sobald das Backend sie liefert (Metriken-Paket WP11). Bis dahin zeigt
		das Dashboard hier nichts an, statt Nullen zu erfinden.
	</p>
</div>
