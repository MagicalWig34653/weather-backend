<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/client.js';
	import type { AuditAction } from '#lib/api.js';
	import { Resource } from '#lib/resource.svelte.js';
	import { formatDateTime } from '#lib/format.js';
	import { Badge } from '#lib/components/ui/badge/index.js';
	import * as Alert from '#lib/components/ui/alert/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import * as Table from '#lib/components/ui/table/index.js';

	const audit = new Resource(() => api.audit(100));
	onMount(() => void audit.load());

	const labels: Record<AuditAction, string> = {
		set: 'Geändert',
		reset: 'Auf Standard',
		restart: 'Neustart',
		login: 'Anmeldung',
		setup: 'Einrichtung',
		'dashboard-reset': 'Notfall-Reset'
	};
</script>

<div class="space-y-1">
	<h1 class="text-2xl font-semibold tracking-tight">Änderungsprotokoll</h1>
	<p class="text-muted-foreground text-sm">Wer, wann, was. Geheimnisse werden nie protokolliert.</p>
</div>

{#if audit.error}
	<Alert.Root variant="destructive"><Alert.Description>{audit.error}</Alert.Description></Alert.Root
	>
{:else if !audit.data}
	<p class="text-muted-foreground" role="status">Lade …</p>
{:else}
	<Card.Root>
		<Card.Content>
			<Table.Root>
				<Table.Header>
					<Table.Row>
						<Table.Head>Zeitpunkt</Table.Head>
						<Table.Head>Aktion</Table.Head>
						<Table.Head>Schlüssel</Table.Head>
						<Table.Head>Alt</Table.Head>
						<Table.Head>Neu</Table.Head>
						<Table.Head>Akteur</Table.Head>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each audit.data.entries as e (e.id)}
						<Table.Row>
							<Table.Cell class="whitespace-nowrap tabular-nums">{formatDateTime(e.at)}</Table.Cell>
							<Table.Cell><Badge variant="secondary">{labels[e.action]}</Badge></Table.Cell>
							<Table.Cell class="font-mono text-xs">{e.key ?? '–'}</Table.Cell>
							<Table.Cell class="font-mono text-xs">{e.old_value ?? '–'}</Table.Cell>
							<Table.Cell class="font-mono text-xs">{e.new_value ?? '–'}</Table.Cell>
							<Table.Cell>{e.actor === 'operator' ? 'Betreiber' : 'System'}</Table.Cell>
						</Table.Row>
					{:else}
						<Table.Row
							><Table.Cell colspan={6} class="text-muted-foreground text-center"
								>Noch keine Einträge.</Table.Cell
							></Table.Row
						>
					{/each}
				</Table.Body>
			</Table.Root>
		</Card.Content>
	</Card.Root>
{/if}
