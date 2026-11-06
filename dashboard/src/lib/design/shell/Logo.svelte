<script lang="ts">
	import { asset } from '$app/paths';
	let { size = 32 }: { size?: number } = $props();
</script>

<span class="inline-flex items-center gap-2.5">
	<img
		src={asset('icons/icon-64.png')}
		alt=""
		width={size}
		height={size}
		class="shrink-0 rounded-[22%]"
	/>
	<span class="leading-tight">
		<span class="block text-[15px] font-semibold tracking-tight">Showers</span>
		<span class="text-muted-foreground block text-[11px] font-medium tracking-wide uppercase"
			>Betrieb</span
		>
	</span>
</span>
