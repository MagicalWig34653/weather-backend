<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/client.js';
	import { Resource } from '#lib/resource.svelte.js';
	import { formatDateTime, formatNumber, formatPercent } from '#lib/format.js';
	import StatCard from '#lib/components/stat-card.svelte';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import * as Table from '#lib/components/ui/table/index.js';
	import * as Alert from '#lib/components/ui/alert/index.js';

	const overview = new Resource(() => api.overview());
	onMount(() => {
		void overview.load();
		const t = setInterval(() => void overview.load(), 60_000);
		return () => clearInterval(t);
	});

	const statusLabel = { ok: 'aktuell', stale: 'veraltet', missing: 'fehlt' } as const;
	const statusVariant = { ok: 'secondary', stale: 'outline', missing: 'destructive' } as const;
</script>

<div class="space-y-1">
	<h1 class="text-2xl font-semibold tracking-tight">Übersicht</h1>
	<p class="text-muted-foreground text-sm">
		Cache-Treffer, Anfragen und Ebenenstatus.
		{#if overview.data}
			Stand {formatDateTime(overview.data.generated_at)}; die Zähler laufen bis zu {overview.data
				.lag_seconds}
			Sekunden nach.
		{/if}
	</p>
</div>

{#if overview.error}
	<Alert.Root variant="destructive"
		><Alert.Description>{overview.error}</Alert.Description></Alert.Root
	>
{:else if !overview.data}
	<p class="text-muted-foreground" role="status">Lade …</p>
{:else}
	{@const o = overview.data}
	<section aria-label="Kennzahlen" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
		<StatCard
			title="Cache-Quote heute"
			value={formatPercent(o.cache_today.ratio)}
			hint="{formatNumber(o.cache_today.hits)} Treffer, {formatNumber(
				o.cache_today.misses
			)} Fehlgriffe"
		/>
		<StatCard
			title="Cache-Quote 30 Tage"
			value={formatPercent(o.cache_30d.ratio)}
			hint="{formatNumber(o.cache_30d.hits)} Treffer, {formatNumber(o.cache_30d.misses)} Fehlgriffe"
		/>
		<StatCard
			title="Anfragen heute"
			value={formatNumber(o.requests_today)}
			hint="alle öffentlichen Routen"
		/>
		<StatCard
			title="Installationen"
			value={formatNumber(o.gauges.installations)}
			hint="{formatNumber(o.gauges.subscriptions)} Abos, {formatNumber(
				o.gauges.regions_cells
			)} Regionszellen"
		/>
	</section>

	<Card.Root>
		<Card.Header>
			<Card.Title>Ebenenstatus</Card.Title>
			<Card.Description>Zeitpunkt der jüngsten gespeicherten Aufnahme je Ebene.</Card.Description>
		</Card.Header>
		<Card.Content>
			<Table.Root>
				<Table.Header>
					<Table.Row>
						<Table.Head>Ebene</Table.Head>
						<Table.Head>Status</Table.Head>
						<Table.Head class="text-right">Jüngste Aufnahme</Table.Head>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each o.layers as layer (layer.id)}
						<Table.Row>
							<Table.Cell class="font-medium">{layer.name}</Table.Cell>
							<Table.Cell
								><Badge variant={statusVariant[layer.status]}>{statusLabel[layer.status]}</Badge
								></Table.Cell
							>
							<Table.Cell class="text-right tabular-nums"
								>{formatDateTime(layer.updated_at)}</Table.Cell
							>
						</Table.Row>
					{/each}
				</Table.Body>
			</Table.Root>
		</Card.Content>
	</Card.Root>
{/if}
