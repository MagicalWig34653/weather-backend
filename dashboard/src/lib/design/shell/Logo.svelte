<script lang="ts">
	import AppIcon from './AppIcon.svelte';
	let { size = 32 }: { size?: number } = $props();
</script>

<span class="inline-flex items-center gap-2.5">
	<AppIcon {size} />
	<span class="leading-tight">
		<span class="block text-[15px] font-semibold tracking-tight">Showers</span>
		<span class="text-muted-foreground block text-[11px] font-medium tracking-wide uppercase"
			>Betrieb</span
		>
	</span>
</span>
