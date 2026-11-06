<script lang="ts">
	import PageHeader from '#lib/design/PageHeader.svelte';
	import { api } from '#lib/client.js';
	import type { AuditAction, AuditEntry } from '#lib/api.js';
	import { formatDateTime } from '#lib/format.js';
	import DataTable from '#lib/design/DataTable.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import { liveStatic } from '#lib/insights/live.svelte.js';

	const audit = liveStatic(() => api.audit(100));

	const labels: Record<AuditAction, string> = {
		set: 'Geändert',
		reset: 'Auf Standard',
		restart: 'Neustart',
		login: 'Anmeldung',
		setup: 'Einrichtung',
		'dashboard-reset': 'Notfall-Reset'
	};
</script>

<PageHeader
	title="Änderungsprotokoll"
	description="Wer, wann, was. Geheimnisse werden nie protokolliert."
/>

<Loadable res={audit}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		<Panel flush>
			<DataTable
				caption="Änderungsprotokoll"
				rows={o.entries}
				rowKey={(e) => e.id}
				empty="Noch keine Einträge."
				columns={[
					{ key: 'at', label: 'Zeitpunkt', format: (e) => formatDateTime(e.at) },
					{ key: 'action', label: 'Aktion', cell: actionCell },
					{
						key: 'key',
						label: 'Schlüssel',
						class: 'font-mono text-xs',
						format: (e) => e.key ?? '–'
					},
					{
						key: 'old',
						label: 'Alt',
						class: 'font-mono text-xs',
						format: (e) => e.old_value ?? '–'
					},
					{
						key: 'new',
						label: 'Neu',
						class: 'font-mono text-xs',
						format: (e) => e.new_value ?? '–'
					},
					{
						key: 'actor',
						label: 'Akteur',
						format: (e) => (e.actor === 'operator' ? 'Betreiber' : 'System')
					}
				]}
			/>
		</Panel>
	{/snippet}
</Loadable>

{#snippet actionCell(e: AuditEntry)}
	<StatusBadge tone="neutral" icon={false} label={labels[e.action]} />
{/snippet}
