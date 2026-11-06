<script lang="ts">
	import RankBars from '#lib/charts/RankBars.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import { formatNumber, formatPercent } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';

	const res = liveStatic(() => insights.distribution());
</script>

<PageHeader
	title="Abos und Verteilung"
	description="Aggregierte Verteilungen. Gruppen unter dem Mindestwert werden unterdrückt."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		{#if o.groups.length === 0}
			<Panel
				><EmptyState
					title="Noch keine Installationen"
					reason="Verteilungen erscheinen, sobald die ersten Installationen Push registrieren."
				/></Panel
			>
		{:else}
			<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
				{#each o.groups as g (g.id)}
					{@const shown = g.items.filter((i) => i.count !== null)}
					{@const hidden = g.items.filter((i) => i.count === null).length}
					<Panel title={g.title}>
						<RankBars
							label={g.title}
							format={formatNumber}
							items={shown.map((i) => ({ label: i.label, value: i.count ?? 0 }))}
						/>
						{#if hidden > 0}
							<p class="text-muted-foreground mt-4 border-t pt-3 text-[12px]">
								{hidden === 1 ? 'Eine Gruppe' : `${hidden} Gruppen`} mit weniger als {o.minGroup} Installationen
								{hidden === 1 ? 'wird' : 'werden'} nicht angezeigt (Datenschutz).
							</p>
						{/if}
					</Panel>
				{/each}
			</div>

			<Panel
				title="Füllgrade"
				description="Auslastung wichtiger Grenzen."
				info="Zeigt, wie nah Cache, Regionsspeicher und Warteschlange an ihrer Grenze sind."
			>
				<RankBars
					label="Füllgrade"
					max={1}
					color={3}
					items={o.fill.map((f) => ({
						label: f.label,
						value: f.ratio,
						display: formatPercent(f.ratio),
						note: f.note
					}))}
				/>
			</Panel>
		{/if}
	{/snippet}
</Loadable>
