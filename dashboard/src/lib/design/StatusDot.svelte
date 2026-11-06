<script lang="ts">
	import { toneFill, toneLabel, type Tone } from './tone.js';
	let { tone = 'neutral', label }: { tone?: Tone; label?: string } = $props();
</script>

<!-- Der Punkt ist Zierde; die Bedeutung steht im Text (label oder umgebender Text). -->
<span
	class="inline-block size-2 shrink-0 rounded-full {toneFill[tone]}"
	role={label ? 'img' : undefined}
	aria-label={label ?? undefined}
	aria-hidden={label ? undefined : 'true'}
	title={label ?? toneLabel[tone]}
></span>
