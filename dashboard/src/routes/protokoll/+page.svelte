<script lang="ts">
	import ScrollTextIcon from '@lucide/svelte/icons/scroll-text';
	import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
	import ChevronRightIcon from '@lucide/svelte/icons/chevron-right';
	import { untrack } from 'svelte';
	import { api } from '#lib/client.js';
	import {
		actionOptions,
		actorLabel,
		actorOf,
		applyFilter,
		clip,
		details,
		labelOf,
		paginate,
		periods,
		subject,
		type Actor,
		type Period
	} from '#lib/audit.js';
	import type { AuditEntry } from '#lib/api.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import * as Dialog from '#lib/components/ui/dialog/index.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import DataTable from '#lib/design/DataTable.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import Segmented from '#lib/design/Segmented.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { formatDateTime } from '#lib/format.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';

	const LIMIT = 200;
	const PAGE = 25;

	let action = $state('');
	let period = $state<Period>('all');
	let actor = $state<Actor | 'all'>('all');
	let page = $state(1);

	// Die Aktion filtert der Server (und verschiebt dabei die 200er-Grenze); Zeitraum und Akteur filtert der Client.
	const res = liveStatic(() => api.audit(LIMIT, action || undefined));
	let lastAction = untrack(() => action);
	$effect(() => {
		if (action !== lastAction) {
			lastAction = action;
			page = 1;
			void res.load();
		}
	});

	const filtered = (all: AuditEntry[]) => applyFilter(all, { period, actor }, ctx.now);
	const reset = () => {
		page = 1;
	};

	let detail = $state<AuditEntry | null>(null);
	let open = $state(false);
	const show = (e: AuditEntry) => ((detail = e), (open = true));

	const tone = (a: string) =>
		a === 'reset_cli'
			? 'err'
			: a === 'restart' || a === 'push_pause' || a === 'cache_clear'
				? 'warn'
				: 'neutral';
</script>

<PageHeader
	title="Änderungsprotokoll"
	description="Wer, wann, was: Konfiguration, Neustarts, Anmeldungen, Geräte und Pausen. Werte von Geheimnissen werden nie protokolliert."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		{@const rows = filtered(o.entries)}
		{@const pg = paginate(rows, page, PAGE)}
		<Panel flush>
			<div class="flex flex-wrap items-end gap-x-5 gap-y-3 px-4 pt-4 sm:px-5">
				<div class="space-y-1">
					<label for="f-action" class="text-muted-foreground block text-xs font-medium"
						>Aktion</label
					>
					<select
						id="f-action"
						bind:value={action}
						class="border-input bg-background focus-visible:ring-ring/50 h-8 w-48 rounded-lg border px-2 text-sm outline-none focus-visible:ring-3"
					>
						<option value="">Alle Aktionen</option>
						{#each actionOptions as a (a.value)}<option value={a.value}>{a.label}</option>{/each}
					</select>
				</div>
				<div class="space-y-1">
					<span class="text-muted-foreground block text-xs font-medium" id="f-period">Zeitraum</span
					>
					<Segmented
						label="Zeitraum"
						size="sm"
						value={period}
						options={periods.map((p) => ({ value: p.value, label: p.label, title: p.title }))}
						onchange={(v) => ((period = v as Period), reset())}
					/>
				</div>
				<div class="space-y-1">
					<span class="text-muted-foreground block text-xs font-medium" id="f-actor">Akteur</span>
					<Segmented
						label="Akteur"
						size="sm"
						value={actor}
						options={[
							{ value: 'all', label: 'Alle' },
							{ value: 'operator', label: 'Betreiber', title: actorLabel.operator },
							{ value: 'cli', label: 'Kommandozeile', title: actorLabel.cli }
						]}
						onchange={(v) => ((actor = v as Actor | 'all'), reset())}
					/>
				</div>
				<p class="text-muted-foreground ml-auto text-[13px]" role="status">
					{pg.total === 0 ? 'Keine Einträge' : `${pg.from} bis ${pg.to} von ${pg.total}`}
				</p>
			</div>

			{#if o.entries.length === 0}
				<EmptyState
					icon={ScrollTextIcon}
					title={action ? 'Keine Einträge zu dieser Aktion' : 'Noch keine Einträge'}
					reason={action
						? 'Wähle eine andere Aktion oder zeige alle an.'
						: 'Änderungen, Anmeldungen und Geräteaktionen erscheinen hier.'}
				/>
			{:else}
				<div class="mt-3">
					<DataTable
						caption="Änderungsprotokoll"
						rows={pg.items}
						rowKey={(e) => e.id}
						empty="Kein Eintrag passt zu den Filtern."
						columns={[
							{ key: 'at', label: 'Zeitpunkt', format: (e) => formatDateTime(e.at) },
							{ key: 'action', label: 'Aktion', cell: actionCell },
							{
								key: 'subject',
								label: 'Betreff',
								class: 'font-mono text-xs',
								format: (e) => clip(subject(e), 70)
							},
							{ key: 'actor', label: 'Akteur', format: (e) => actorLabel[actorOf(e)] },
							{ key: 'detail', label: 'Details', cell: detailCell }
						]}
					/>
				</div>
				{#if o.entries.length >= LIMIT}
					<p class="text-muted-foreground px-4 pt-2 text-xs sm:px-5">
						Der Server liefert höchstens {LIMIT} Einträge; ältere sind hier nicht abrufbar.
					</p>
				{/if}
				<nav
					class="flex items-center justify-between gap-3 px-4 py-3 sm:px-5"
					aria-label="Seiten des Protokolls"
				>
					<Button
						variant="outline"
						size="sm"
						disabled={pg.page <= 1}
						onclick={() => (page = pg.page - 1)}
					>
						<ChevronLeftIcon aria-hidden="true" />Neuere
					</Button>
					<span class="text-muted-foreground num text-[13px]">Seite {pg.page} von {pg.pages}</span>
					<Button
						variant="outline"
						size="sm"
						disabled={pg.page >= pg.pages}
						onclick={() => (page = pg.page + 1)}
					>
						Ältere<ChevronRightIcon aria-hidden="true" />
					</Button>
				</nav>
			{/if}
		</Panel>
	{/snippet}
</Loadable>

{#snippet actionCell(e: AuditEntry)}
	<StatusBadge tone={tone(e.action)} icon={false} label={labelOf(e.action)} />
{/snippet}
{#snippet detailCell(e: AuditEntry)}
	<Button variant="ghost" size="sm" onclick={() => show(e)} aria-label="Details zu Eintrag {e.id}"
		>Details</Button
	>
{/snippet}

<Dialog.Root bind:open>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>Eintrag {detail?.id}</Dialog.Title>
			<Dialog.Description>
				{detail ? labelOf(detail.action) : ''}: Angezeigt wird, was der Server protokolliert hat.
				Geheimnisse stehen nie im Klartext darin.
			</Dialog.Description>
		</Dialog.Header>
		{#if detail}
			<dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-5 gap-y-2 text-sm">
				{#each details(detail) as d (d.label)}
					<dt class="text-muted-foreground">{d.label}</dt>
					<dd class="{d.mono ? 'font-mono text-[13px]' : ''} break-all">{d.value}</dd>
				{/each}
			</dl>
		{/if}
		<Dialog.Footer>
			<Button variant="outline" onclick={() => (open = false)}>Schließen</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
