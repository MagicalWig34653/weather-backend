<script lang="ts">
	/** Segmentierte Auswahl als Radiogruppe (Pfeiltasten, Roving-Tabindex). */
	interface Option {
		value: string;
		label: string;
		/** Langer Text fuer Screenreader, z. B. "Letzte 24 Stunden". */
		title?: string;
	}
	let {
		options,
		value,
		onchange,
		label,
		size = 'md'
	}: {
		options: Option[];
		value: string;
		onchange: (v: string) => void;
		label: string;
		size?: 'sm' | 'md';
	} = $props();

	let group: HTMLDivElement | undefined = $state();

	function onkeydown(e: KeyboardEvent, i: number): void {
		let next: number;
		if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (i + 1) % options.length;
		else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp')
			next = (i - 1 + options.length) % options.length;
		else if (e.key === 'Home') next = 0;
		else if (e.key === 'End') next = options.length - 1;
		else return;
		e.preventDefault();
		onchange(options[next].value);
		group?.querySelectorAll<HTMLElement>('[role=radio]')[next]?.focus();
	}
</script>

<div
	bind:this={group}
	role="radiogroup"
	aria-label={label}
	class="bg-muted inline-flex shrink-0 rounded-lg p-0.5"
>
	{#each options as o, i (o.value)}
		{@const on = o.value === value}
		<button
			type="button"
			role="radio"
			aria-checked={on}
			aria-label={o.title}
			tabindex={on ? 0 : -1}
			onclick={() => onchange(o.value)}
			onkeydown={(e) => onkeydown(e, i)}
			class="rounded-md px-3 font-medium whitespace-nowrap transition-colors {size === 'sm'
				? 'h-7 text-xs'
				: 'h-8 text-[13px]'} {on
				? 'bg-card text-foreground shadow-card ring-1 ring-black/5 dark:ring-white/10'
				: 'text-muted-foreground hover:text-foreground'}"
		>
			{o.label}
		</button>
	{/each}
</div>
