<script lang="ts">
	import Segmented from '../Segmented.svelte';
	import { theme, type ThemeChoice } from '#lib/theme.svelte.js';
</script>

<Segmented
	label="Farbschema"
	size="sm"
	value={theme.choice}
	onchange={(v) => theme.set(v as ThemeChoice)}
	options={[
		{ value: 'system', label: 'Auto', title: 'Automatisch (System)' },
		{ value: 'light', label: 'Hell' },
		{ value: 'dark', label: 'Dunkel' }
	]}
/>
