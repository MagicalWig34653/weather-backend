<script lang="ts">
	import SmartphoneIcon from '@lucide/svelte/icons/smartphone';
	import BellRingIcon from '@lucide/svelte/icons/bell-ring';
	import PlayIcon from '@lucide/svelte/icons/play';
	import SquareIcon from '@lucide/svelte/icons/square';
	import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
	import UnlinkIcon from '@lucide/svelte/icons/unlink';
	import { ApiError } from '#lib/api.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import { Input } from '#lib/components/ui/input/index.js';
	import { Label } from '#lib/components/ui/label/index.js';
	import ConfirmDialog from '#lib/design/ConfirmDialog.svelte';
	import EmptyState from '#lib/design/EmptyState.svelte';
	import Loadable from '#lib/design/Loadable.svelte';
	import PageHeader from '#lib/design/PageHeader.svelte';
	import Panel from '#lib/design/Panel.svelte';
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import { toast } from '#lib/design/toast.svelte.js';
	import { toneIcon, toneText } from '#lib/design/tone.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import { formatAgo, formatDateTime } from '#lib/format.js';
	import { insights } from '#lib/insights/api.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import type { DeviceAction, LinkedDevice } from '#lib/insights/types.js';

	const res = liveStatic(() => insights.devices());

	const channel = {
		testflight: 'TestFlight',
		appstore: 'App Store',
		debug: 'Debug',
		unknown: 'Unbekannt'
	} as const;
	const actions: { id: DeviceAction; label: string; icon: typeof PlayIcon; consequence: string }[] =
		[
			{
				id: 'test-push',
				label: 'Testpush',
				icon: BellRingIcon,
				consequence: 'Eine Testmitteilung wird sofort an dieses Gerät gesendet.'
			},
			{
				id: 'la-start',
				label: 'Live Activity starten',
				icon: PlayIcon,
				consequence:
					'Eine Live Activity wird auf diesem Gerät gestartet, sofern der Start-Token vorhanden ist.'
			},
			{
				id: 'la-end',
				label: 'Live Activity beenden',
				icon: SquareIcon,
				consequence: 'Eine laufende Live Activity auf diesem Gerät wird beendet.'
			},
			{
				id: 're-evaluate',
				label: 'Neu auswerten',
				icon: RefreshCwIcon,
				consequence:
					'Die Regenauswertung für die Abos dieses Geräts läuft sofort erneut; es kann eine Meldung folgen.'
			}
		];

	let pending = $state<{ device: LinkedDevice; action: DeviceAction } | null>(null);
	let open = $state(false);
	let busy = $state(false);
	const pendingInfo = $derived(
		pending?.action === 'unlink'
			? {
					label: 'Kopplung widerrufen',
					consequence:
						'Das Gerät verschwindet aus dem Dashboard; Ereignisse und Diagnose werden gelöscht. In der App lässt sich erneut koppeln.'
				}
			: actions.find((a) => a.id === pending?.action)
	);

	function ask(device: LinkedDevice, action: DeviceAction): void {
		pending = { device, action };
		open = true;
	}

	async function run(): Promise<void> {
		if (!pending) return;
		busy = true;
		try {
			const r = await insights.deviceAction(pending.device.ref, pending.action);
			toast.success(r.message, pending.device.name);
			open = false;
			void res.load();
		} catch (e) {
			toast.error(
				'Aktion fehlgeschlagen',
				e instanceof ApiError ? e.message : 'Unbekannter Fehler.'
			);
		} finally {
			busy = false;
		}
	}

	let code = $state('');
	let linking = $state(false);
	let codeError = $state<string | null>(null);
	async function link(e: Event): Promise<void> {
		e.preventDefault();
		linking = true;
		codeError = null;
		try {
			await insights.linkDevice(code.trim().toUpperCase());
			code = '';
			toast.success('Gerät gekoppelt');
			await res.load();
		} catch (err) {
			codeError = err instanceof ApiError ? err.message : 'Unbekannter Fehler.';
		} finally {
			linking = false;
		}
	}
</script>

<PageHeader
	title="Geräte"
	description="Eigene Geräte, die in der App freiwillig mit dem Dashboard gekoppelt wurden: Diagnose und manuelle Aktionen."
/>

<Loadable {res}>
	{#snippet skeleton()}
		<Skeletons kind="list" />
	{/snippet}
	{#snippet children(o)}
		{#if o.devices.length === 0}
			<Panel>
				<EmptyState
					icon={SmartphoneIcon}
					title="Kein Gerät gekoppelt"
					reason="Aktiviere in der App unter Info den Schalter „Mit Dashboard koppeln“ und gib den angezeigten Code unten ein."
				/>
			</Panel>
		{/if}

		{#each o.devices as d (d.ref)}
			<Panel
				title={d.name}
				description="Zuletzt gesehen {formatAgo(
					d.lastSeenAt,
					ctx.now
				)} · gekoppelt bis {formatDateTime(d.expiresAt)}"
			>
				<div class="mb-4 flex flex-wrap gap-2">
					<StatusBadge tone="info" icon={false} label={channel[d.channel]} />
					<StatusBadge tone="neutral" icon={false} label="APNs {d.env}" />
				</div>

				<h3 class="mb-2 text-[13px] font-semibold">Diagnose</h3>
				<ul class="divide-y rounded-lg border">
					{#each d.diagnosis as item (item.id)}
						{@const Icon = toneIcon[item.tone]}
						<li class="flex items-start gap-3 px-3.5 py-3">
							<Icon class="mt-0.5 size-4 shrink-0 {toneText[item.tone]}" aria-hidden="true" />
							<div class="min-w-0">
								<p class="text-sm font-medium">
									{item.label}<span class="sr-only"
										>: {item.tone === 'ok'
											? 'in Ordnung'
											: item.tone === 'warn'
												? 'Warnung'
												: 'Fehler'}</span
									>
								</p>
								<p class="text-muted-foreground text-[13px]">{item.detail}</p>
							</div>
						</li>
					{/each}
				</ul>

				<h3 class="mt-5 mb-2 text-[13px] font-semibold">Aktionen</h3>
				<div class="flex flex-wrap gap-2">
					{#each actions as a (a.id)}
						{@const Icon = a.icon}
						<Button variant="outline" size="sm" onclick={() => ask(d, a.id)}
							><Icon aria-hidden="true" />{a.label}</Button
						>
					{/each}
					<Button
						variant="ghost"
						size="sm"
						class="text-destructive hover:text-destructive"
						onclick={() => ask(d, 'unlink')}><UnlinkIcon aria-hidden="true" />Widerrufen</Button
					>
				</div>

				<h3 class="mt-5 mb-2 text-[13px] font-semibold">Verlauf</h3>
				<ol class="relative ml-1.5 flex flex-col gap-4 border-l pl-5">
					{#each d.events as ev (ev.at + ev.kind)}
						{@const Icon = toneIcon[ev.tone === 'info' ? 'info' : ev.tone]}
						<li class="relative">
							<span
								class="bg-card absolute top-0.5 -left-[1.9rem] inline-flex size-5 items-center justify-center rounded-full"
							>
								<Icon
									class="size-4 {toneText[ev.tone === 'info' ? 'info' : ev.tone]}"
									aria-hidden="true"
								/>
							</span>
							<p class="text-sm font-medium">{ev.kind}</p>
							<p class="text-muted-foreground text-[13px]">{ev.detail}</p>
							<p class="text-muted-foreground num text-[12px]">
								<time datetime={ev.at}>{formatDateTime(ev.at)}</time>
							</p>
						</li>
					{/each}
				</ol>
			</Panel>
		{/each}

		<Panel
			title="Gerät koppeln"
			description="{o.devices.length} von {o.maxDevices} Plätzen belegt."
			info="Der Code wird in der App angezeigt, gilt kurz und nur einmal. Es werden nur Zustände und Zähler gespeichert, keine Tokens oder Standorte."
		>
			{#if o.devices.length >= o.maxDevices}
				<p class="text-muted-foreground text-sm">
					Alle Plätze sind belegt. Widerrufe zuerst eine Kopplung.
				</p>
			{:else}
				<form onsubmit={link} class="flex max-w-md flex-col gap-3 sm:flex-row sm:items-end">
					<div class="flex-1 space-y-1.5">
						<Label for="link-code">Koppelcode aus der App</Label>
						<Input
							id="link-code"
							bind:value={code}
							placeholder="ABCD-EFGH"
							autocomplete="off"
							autocapitalize="characters"
							spellcheck={false}
							class="font-mono tracking-widest"
							aria-describedby={codeError ? 'link-err' : undefined}
							aria-invalid={codeError ? true : undefined}
						/>
					</div>
					<Button type="submit" disabled={linking || code.trim().length < 9}
						>{linking ? 'Prüfe …' : 'Koppeln'}</Button
					>
				</form>
				{#if codeError}<p id="link-err" role="alert" class="text-destructive mt-2 text-[13px]">
						{codeError}
					</p>{/if}
			{/if}
		</Panel>
	{/snippet}
</Loadable>

<ConfirmDialog
	bind:open
	title="{pendingInfo?.label ?? 'Aktion'}?"
	description={pendingInfo?.consequence ?? ''}
	confirmLabel={pendingInfo?.label ?? 'Bestätigen'}
	destructive={pending?.action === 'unlink'}
	{busy}
	onconfirm={run}
/>
