<script lang="ts">
	import { asset } from '$app/paths';
	// Hell-/Dunkel-Variante des App-Icons. Beide <img> liegen im DOM, die Sichtbarkeit steuert
	// die .dark-Klasse am <html> (ThemeSwitch bzw. System): kein Flackern, kein Layout-Sprung.
	let { size = 32, class: cls = '' }: { size?: number; class?: string } = $props();
</script>

<img
	src={asset('icons/icon-64.png')}
	srcset="{asset('icons/icon-64.png')} 1x, {asset('icons/icon-192.png')} 3x"
	alt=""
	width={size}
	height={size}
	class="shrink-0 rounded-[22%] dark:hidden {cls}"
	data-icon="light"
/>
<img
	src={asset('icons/icon-64-dark.png')}
	srcset="{asset('icons/icon-64-dark.png')} 1x, {asset('icons/icon-192-dark.png')} 3x"
	alt=""
	width={size}
	height={size}
	class="hidden shrink-0 rounded-[22%] dark:block {cls}"
	data-icon="dark"
/>
