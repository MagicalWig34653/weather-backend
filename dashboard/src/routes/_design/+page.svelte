<script lang="ts">
	import Donut from '#lib/charts/Donut.svelte';
	import HeatStrip from '#lib/charts/HeatStrip.svelte';
	import RankBars from '#lib/charts/RankBars.svelte';
	import Sparkline from '#lib/charts/Sparkline.svelte';
	import XYChart from '#lib/charts/XYChart.svelte';
	import { Button } from '#lib/components/ui/button/index.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import ErrorState from '#lib/design/ErrorState.svelte';
	import Kpi from '#lib/design/Kpi.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import Skeleton from '#lib/design/Skeleton.svelte';
	import StaleNotice from '#lib/design/StaleNotice.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import StatusDot from '#lib/design/StatusDot.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import type { Tone } from '#lib/design/tone.js';

	const tones: Tone[] = ['ok', 'warn', 'err', 'info', 'neutral'];
	const surfaces = [
		'background',
		'card',
		'muted',
		'accent',
		'primary',
		'primary-soft',
		'ok-soft',
		'warn-soft',
		'destructive-soft'
	];
	const wave = Array.from({ length: 24 }, (_, i) =>
		Math.round(120 + 60 * Math.sin(i / 3) + (i % 5) * 9)
	);
	const cats = wave.map((_, i) => `${String(i).padStart(2, '0')}:00`);
	let dialog = $state(false);
</script>

<PageHeader
	title="Designsystem"
	description="Vorschau der Tokens und Bausteine (nur Entwicklungs-/Mock-Build)."
/>

<Panel title="Farben">
	<ul class="grid grid-cols-3 gap-3 sm:grid-cols-5">
		{#each surfaces as s (s)}
			<li class="text-[12px]">
				<div class="h-12 rounded-lg border" style:background="var(--{s})"></div>
				<p class="mt-1 font-mono">{s}</p>
			</li>
		{/each}
	</ul>
	<div class="mt-4 flex flex-wrap items-center gap-2">
		{#each tones as t (t)}<StatusBadge tone={t} label={t} /><StatusDot tone={t} />{/each}
	</div>
</Panel>

<Panel title="Typografie">
	<p class="text-2xl font-semibold tracking-tight">Überschrift 24 · Inter Variable</p>
	<p class="text-[15px] font-semibold">Abschnitt 15 / Text 14 / Klein 13 / Mikro 12</p>
	<p class="num mt-2 text-[28px] font-semibold">
		1.234.567,89 <span class="text-muted-foreground text-sm">ms</span>
	</p>
	<p class="text-muted-foreground font-mono text-xs">/v1/radar/:layer/:slot · APNS_ENV</p>
</Panel>

<div class="grid grid-cols-2 gap-4 xl:grid-cols-4">
	<Kpi label="Anfragen" value="40.482" delta={0.075} goodWhen="none" series={wave} />
	<Kpi
		label="Fehlerquote"
		value="0,4"
		unit="%"
		delta={0.21}
		goodWhen="down"
		tone="warn"
		series={wave}
	/>
	<Kpi label="Cache" value="94,8 %" delta={-0.02} tone="ok" series={wave} />
	<Kpi label="Ohne Vergleich" value="12" hint="kein Vorzeitraum" />
</div>

<div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
	<Panel
		title="Linie und Fläche"
		info="Tooltip per Zeiger und Pfeiltasten, Tabellenansicht umschaltbar."
	>
		<XYChart
			label="Beispiel Fläche"
			kind="area"
			categories={cats}
			series={[
				{ key: 'a', label: 'Wert', values: wave, color: 1 },
				{ key: 'b', label: 'Vergleich', values: wave.map((v) => v * 0.6), color: 3 }
			]}
		/>
	</Panel>
	<Panel title="Gestapelte Balken">
		<XYChart
			label="Beispiel Balken"
			kind="bar"
			stacked
			categories={cats}
			series={[
				{ key: 'a', label: 'Erfolg', values: wave, color: 1 },
				{ key: 'b', label: 'Fehler', values: wave.map((v) => v / 9), color: 'err' }
			]}
		/>
	</Panel>
	<Panel title="Rangbalken, Donut, Sparkline">
		<RankBars
			label="Beispiel"
			items={[
				{ label: 'Eins', value: 80 },
				{ label: 'Zwei', value: 45 },
				{ label: 'Drei', value: 12 }
			]}
		/>
		<div class="mt-6">
			<Donut
				label="Beispiel Donut"
				centerValue="100"
				centerLabel="gesamt"
				parts={[
					{ label: 'A', value: 60, color: 1 },
					{ label: 'B', value: 30, color: 3 },
					{ label: 'C', value: 10, color: 5 }
				]}
			/>
		</div>
		<Sparkline values={wave} class="mt-4 h-10 w-40" />
	</Panel>
	<Panel title="Heat-Strip">
		<HeatStrip
			label="Beispiel"
			rows={[
				{
					label: 'Ebene',
					cells: Array.from({ length: 48 }, (_, i) => ({
						tone: i % 17 === 5 ? 'err' : i % 11 === 3 ? 'warn' : 'ok',
						label: `Lauf ${i + 1}`
					}))
				}
			]}
			keys={[
				{ tone: 'ok', label: 'ok' },
				{ tone: 'warn', label: 'ausgefallen' },
				{ tone: 'err', label: 'Fehler' }
			]}
		/>
	</Panel>
</div>

<div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
	<Panel title="Leer"
		><EmptyState
			compact
			title="Noch keine Daten"
			reason="Zähler erscheinen nach dem ersten Flush (höchstens 60 Sekunden)."
		/></Panel
	>
	<Panel title="Fehler"
		><ErrorState compact message="Der Server hat nicht geantwortet." onretry={() => {}} /></Panel
	>
	<Panel title="Laden und veraltet">
		<div class="space-y-3">
			<Skeleton class="h-6 w-2/3" /><Skeleton class="h-24 w-full" /><StaleNotice
				since={Date.now() - 600_000}
			/>
		</div>
	</Panel>
</div>

<Panel title="Meldungen und Dialog">
	<div class="flex flex-wrap gap-2">
		<Button
			variant="outline"
			onclick={() => toast.success('Gespeichert', 'Wirkt nach höchstens 30 Sekunden.')}
			>Erfolg-Toast</Button
		>
		<Button
			variant="outline"
			onclick={() => toast.error('Fehlgeschlagen', 'Bitte erneut versuchen.')}>Fehler-Toast</Button
		>
		<Button variant="outline" onclick={() => (dialog = true)}>Bestätigungsdialog</Button>
	</div>
</Panel>

<ConfirmDialog
	bind:open={dialog}
	title="Radar-Dienst neu starten?"
	description="2 Replikate starten nacheinander neu."
	confirmLabel="Jetzt neu starten"
	onconfirm={() => {
		dialog = false;
	}}
/>
