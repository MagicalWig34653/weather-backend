<script lang="ts">
	let { class: className = 'h-4 w-full' }: { class?: string } = $props();
</script>

<div class="skeleton {className}" aria-hidden="true"></div>
