<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/client.js';
	import type { DailyMetric, StatusClass } from '#lib/api.js';
	import { Resource } from '#lib/resource.svelte.js';
	import { formatBytes, formatNumber, formatPercent } from '#lib/format.js';
	import BarChart from '#lib/components/bar-chart.svelte';
	import StatCard from '#lib/components/stat-card.svelte';
	import * as Alert from '#lib/components/ui/alert/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import * as Tabs from '#lib/components/ui/tabs/index.js';

	let metric = $state<DailyMetric>('requests');
	const data = new Resource(() => api.daily(metric, 30));

	onMount(() => void data.load());

	function setMetric(m: string): void {
		metric = m as DailyMetric;
		void data.load();
	}

	const fmt = $derived((n: number) => (metric === 'bytes' ? formatBytes(n) : formatNumber(n)));

	const statusSeries = [
		{ key: '2xx', label: 'Erfolg (2xx)', fill: 'fill-chart-2', swatch: 'bg-chart-2' },
		{ key: '3xx', label: 'Nicht geändert (3xx)', fill: 'fill-chart-1', swatch: 'bg-chart-1' },
		{ key: '4xx', label: 'Clientfehler (4xx)', fill: 'fill-chart-3', swatch: 'bg-chart-3' },
		{ key: '5xx', label: 'Serverfehler (5xx)', fill: 'fill-chart-5', swatch: 'bg-chart-5' }
	];
	const routeFills = [
		['fill-chart-1', 'bg-chart-1'],
		['fill-chart-2', 'bg-chart-2'],
		['fill-chart-3', 'bg-chart-3'],
		['fill-chart-4', 'bg-chart-4']
	];

	const routeSeries = $derived.by(() => {
		const keys = [...new Set((data.data?.days ?? []).flatMap((d) => Object.keys(d.routes)))].sort();
		return keys.map((key, i) => ({
			key,
			label: key,
			fill: routeFills[i % routeFills.length][0],
			swatch: routeFills[i % routeFills.length][1]
		}));
	});

	const totals = $derived.by(() => {
		const days = data.data?.days ?? [];
		const sum = (f: (d: (typeof days)[number]) => number) => days.reduce((s, d) => s + f(d), 0);
		const all = sum((d) => Object.values(d.status).reduce((a, b) => a + b, 0));
		return {
			all,
			notModified: all ? sum((d) => d.status['3xx' as StatusClass]) / all : null,
			rateLimited: sum((d) => d.rate_limited)
		};
	});
</script>

<div class="flex flex-wrap items-end justify-between gap-3">
	<div class="space-y-1">
		<h1 class="text-2xl font-semibold tracking-tight">Traffic</h1>
		<p class="text-muted-foreground text-sm">
			Letzte 30 Tage, Tageswerte (UTC). Nur Zähler, keine IP-Adressen.
		</p>
	</div>
	<Tabs.Root value={metric} onValueChange={setMetric}>
		<Tabs.List aria-label="Messgröße">
			<Tabs.Trigger value="requests">Anfragen</Tabs.Trigger>
			<Tabs.Trigger value="bytes">Datenmenge</Tabs.Trigger>
		</Tabs.List>
	</Tabs.Root>
</div>

{#if data.error}
	<Alert.Root variant="destructive"><Alert.Description>{data.error}</Alert.Description></Alert.Root>
{:else if !data.data}
	<p class="text-muted-foreground" role="status">Lade …</p>
{:else}
	<section aria-label="Kennzahlen" class="grid gap-4 sm:grid-cols-3">
		<StatCard
			title={metric === 'bytes' ? 'Datenmenge gesamt' : 'Anfragen gesamt'}
			value={fmt(totals.all)}
			hint="30 Tage"
		/>
		<StatCard
			title="Anteil 304 (nicht geändert)"
			value={formatPercent(totals.notModified)}
			hint="Treffer ohne Neuübertragung"
		/>
		<StatCard
			title="Rate-Limit-Treffer"
			value={formatNumber(totals.rateLimited)}
			hint="Antworten mit 429"
		/>
	</section>

	<Card.Root>
		<Card.Header>
			<Card.Title>Nach Route</Card.Title>
			<Card.Description>Routenvorlagen ohne Parameterwerte.</Card.Description>
		</Card.Header>
		<Card.Content>
			<BarChart
				days={data.data.days.map((d) => ({ date: d.date, values: d.routes }))}
				series={routeSeries}
				format={fmt}
				label="{metric === 'bytes' ? 'Datenmenge' : 'Anfragen'} je Tag und Route"
			/>
		</Card.Content>
	</Card.Root>

	<Card.Root>
		<Card.Header>
			<Card.Title>Nach Statusklasse</Card.Title>
		</Card.Header>
		<Card.Content>
			<BarChart
				days={data.data.days.map((d) => ({ date: d.date, values: d.status }))}
				series={statusSeries}
				format={fmt}
				label="{metric === 'bytes' ? 'Datenmenge' : 'Anfragen'} je Tag und Statusklasse"
			/>
		</Card.Content>
	</Card.Root>
{/if}
