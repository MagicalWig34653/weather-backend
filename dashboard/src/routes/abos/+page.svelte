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
	import { capName } from '#lib/insights/text.js';
	import type { Bucket } from '#lib/insights/types.js';

	const res = liveStatic(() => insights.distribution());

	const envNames = { production: 'Produktiv', sandbox: 'Sandbox' };
	const localeNames = { de: 'Deutsch', en: 'Englisch' };
	const leadNames = { '10': '10 Minuten', '20': '20 Minuten', '30': '30 Minuten' };

	function items(b: Bucket[], names: Record<string, string> = {}, unit = '') {
		return b
			.filter((x) => !x.suppressed)
			.map((x) => ({ label: `${names[x.key] ?? x.key}${unit}`, value: x.count ?? 0 }));
	}
	const hidden = (b: Bucket[]) => b.filter((x) => x.suppressed).length;
</script>

<PageHeader
	title="Abos und Verteilung"
	description="Aggregierte Verteilungen ohne Geografie. Gruppen unter dem Mindestwert werden unterdrückt."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		{@const groups = [
			{ title: 'Abos je Installation', b: o.subscriptionsPerInstallation, names: {}, unit: '' },
			{ title: 'Regionen je Installation', b: o.regionsPerInstallation, names: {}, unit: '' },
			{ title: 'Regenschwelle (Intensitätsklasse)', b: o.threshold, names: {}, unit: '' },
			{ title: 'Vorlaufzeit', b: o.lead, names: leadNames, unit: '' },
			{ title: 'Sprache', b: o.locale, names: localeNames, unit: '' },
			{ title: 'APNs-Umgebung', b: o.env, names: envNames, unit: '' }
		].filter((g) => g.b.length > 0)}

		{#if groups.length === 0}
			<Panel>
				<EmptyState
					title="Noch keine Installationen"
					reason="Verteilungen erscheinen, sobald die ersten Installationen Push registrieren."
				/>
			</Panel>
		{:else}
			<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
				{#each groups as g (g.title)}
					<Panel title={g.title}>
						<RankBars label={g.title} format={formatNumber} items={items(g.b, g.names, g.unit)} />
						{#if hidden(g.b) > 0}
							<p class="text-muted-foreground mt-4 border-t pt-3 text-[12px]">
								{hidden(g.b) === 1 ? 'Eine Gruppe' : `${hidden(g.b)} Gruppen`} mit weniger als {o.minGroup}
								Installationen
								{hidden(g.b) === 1 ? 'wird' : 'werden'} nicht angezeigt (Datenschutz).
							</p>
						{/if}
					</Panel>
				{/each}
			</div>

			{#if o.timeSensitiveShare !== null || o.liveActivityShare !== null}
				<Panel title="Funktionen" description="Anteil der Abos mit aktivierter Funktion.">
					<RankBars
						label="Funktionen"
						max={1}
						color={2}
						items={[
							...(o.timeSensitiveShare === null
								? []
								: [
										{
											label: 'Dringende Mitteilungen',
											value: o.timeSensitiveShare,
											display: formatPercent(o.timeSensitiveShare)
										}
									]),
							...(o.liveActivityShare === null
								? []
								: [
										{
											label: 'Live Activity',
											value: o.liveActivityShare,
											display: formatPercent(o.liveActivityShare)
										}
									])
						]}
					/>
				</Panel>
			{/if}

			<Panel
				title="Füllgrade"
				description="Auslastung wichtiger Obergrenzen."
				info="Zeigt, wie nah Installationen, Abos und Regionsspeicher an ihrer Grenze sind (Befund ab 80 %)."
			>
				<RankBars
					label="Füllgrade"
					max={1}
					color={3}
					items={o.caps.map((c) => ({
						label: capName(c.key),
						value: c.gauge.ratio,
						display: formatPercent(c.gauge.ratio),
						note: `${formatNumber(c.gauge.used)} von ${formatNumber(c.gauge.max)}`
					}))}
				/>
			</Panel>
		{/if}
	{/snippet}
</Loadable>
