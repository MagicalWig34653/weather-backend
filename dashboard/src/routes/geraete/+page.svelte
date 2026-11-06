<script lang="ts">
	import SmartphoneIcon from '@lucide/svelte/icons/smartphone';
	import BellRingIcon from '@lucide/svelte/icons/bell-ring';
	import FlaskConicalIcon from '@lucide/svelte/icons/flask-conical';
	import SquareIcon from '@lucide/svelte/icons/square';
	import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
	import SendIcon from '@lucide/svelte/icons/send';
	import EraserIcon from '@lucide/svelte/icons/eraser';
	import UnlinkIcon from '@lucide/svelte/icons/unlink';
	import type { Component } from 'svelte';
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
	import { toneIcon, toneText, type Tone } from '#lib/design/tone.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import { formatAgo, formatDateTime } from '#lib/format.js';
	import { describeError, insights } from '#lib/insights/api.js';
	import { liveStatic } from '#lib/insights/live.svelte.js';
	import Skeletons from '#lib/insights/Skeletons.svelte';
	import {
		checkName,
		checkText,
		commandResultText,
		eventKindName,
		eventReasonName,
		levelLabel,
		levelTone,
		outcomeName,
		summaryText
	} from '#lib/insights/text.js';
	import type { Device, DeviceAction, DeviceBundle, DeviceList } from '#lib/insights/types.js';

	interface Loaded {
		list: DeviceList;
		bundles: Record<string, DeviceBundle>;
	}
	const res = liveStatic<Loaded>(async () => {
		const list = await insights.devices();
		const entries = await Promise.all(
			list.devices.map(async (d) => [d.id, await insights.deviceBundle(d.id)] as const)
		);
		return { list, bundles: Object.fromEntries(entries) };
	});

	interface ActionDef {
		key: string;
		action: DeviceAction | 'unlink';
		dryRun?: boolean;
		label: string;
		icon: Component;
		consequence: string;
		destructive?: boolean;
	}
	const actions: ActionDef[] = [
		{
			key: 'test',
			action: 'test',
			label: 'Testpush',
			icon: BellRingIcon,
			consequence:
				'Eine Testmitteilung wird sofort an dieses Gerät gesendet (höchstens 3 pro Stunde).'
		},
		{
			key: 'probe',
			action: 'la-probe',
			label: 'Live-Activity-Test',
			icon: FlaskConicalIcon,
			consequence:
				'Der echte Startpfad einer Live Activity wird auf diesem Gerät ausgelöst. Sperrzeit und Hysterese werden ignoriert, Platz und Start-Token nicht (höchstens 3 pro Stunde).'
		},
		{
			key: 'end',
			action: 'la-end',
			label: 'Live Activity beenden',
			icon: SquareIcon,
			consequence: 'Eine laufende Live Activity auf diesem Gerät wird beendet.'
		},
		{
			key: 'dry',
			action: 'reeval',
			dryRun: true,
			label: 'Trockenlauf',
			icon: RefreshCwIcon,
			consequence:
				'Die Regenauswertung läuft für dieses Gerät, es wird nichts gesendet. Das Ergebnis zeigt, warum (nicht) ausgelöst würde.'
		},
		{
			key: 'send',
			action: 'reeval',
			dryRun: false,
			label: 'Neu auswerten und senden',
			icon: SendIcon,
			consequence:
				'Die Regenauswertung läuft für dieses Gerät und sendet eine Meldung, wenn sie auslöst. Sperrzeiten gelten wie im Normalbetrieb (höchstens 3 pro Stunde).'
		},
		{
			key: 'slot',
			action: 'reset-slot',
			label: 'Platz freigeben',
			icon: EraserIcon,
			consequence:
				'Eine offene Reservierung oder eine als laufend vermerkte Live Activity wird zurückgesetzt, damit ein neuer Start möglich ist.'
		},
		{
			key: 'unlink',
			action: 'unlink',
			label: 'Widerrufen',
			icon: UnlinkIcon,
			destructive: true,
			consequence:
				'Das Gerät verschwindet aus dem Dashboard; Ereignisse und Aufträge werden gelöscht. In der App lässt sich erneut koppeln.'
		}
	];

	let pending = $state<{ device: Device; def: ActionDef } | null>(null);
	let open = $state(false);
	let busy = $state(false);
	let running = $state<string | null>(null);

	function ask(device: Device, def: ActionDef): void {
		pending = { device, def };
		open = true;
	}

	const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

	async function run(): Promise<void> {
		if (!pending) return;
		const { device, def } = pending;
		busy = true;
		try {
			if (def.action === 'unlink') {
				await insights.unpairDevice(device.id);
				toast.success('Kopplung widerrufen', device.label);
				open = false;
				ctx.refresh();
				return;
			}
			const started = await insights.runAction(device.id, def.action, def.dryRun);
			open = false;
			running = device.id;
			toast.push('info', `${def.label} läuft …`, device.label, 2500);
			// Der Leader fuehrt den Auftrag aus (Abfrage alle 2 s); hoechstens 2 Minuten warten.
			for (let i = 0; i < 80; i++) {
				await sleep(1500);
				const c = await insights.command(device.id, started.commandId);
				if (c.status === 'done') {
					toast.success(`${def.label}: erledigt`, commandResultText(c.kind, c.result));
					break;
				}
				if (c.status === 'failed' || c.status === 'expired') {
					toast.error(
						`${def.label}: ${c.status === 'expired' ? 'nicht ausgeführt' : 'fehlgeschlagen'}`,
						c.status === 'expired'
							? 'Kein Replikat hat den Auftrag innerhalb von 2 Minuten übernommen.'
							: (c.error ?? 'Unbekannter Fehler.')
					);
					break;
				}
			}
			ctx.refresh();
		} catch (e) {
			toast.error('Aktion fehlgeschlagen', describeError(e));
			open = false;
		} finally {
			busy = false;
			running = null;
		}
	}

	let code = $state('');
	let label = $state('');
	let linking = $state(false);
	let formError = $state<string | null>(null);
	async function pair(e: Event): Promise<void> {
		e.preventDefault();
		linking = true;
		formError = null;
		try {
			const d = await insights.pairDevice(code.trim(), label.trim());
			code = '';
			label = '';
			toast.success('Gerät gekoppelt', d.label);
			ctx.refresh();
		} catch (err) {
			formError = describeError(err);
		} finally {
			linking = false;
		}
	}

	const tone = (l: 'ok' | 'warning' | 'critical' | 'unknown'): Tone => levelTone(l);
	const evTone = (outcome: string): Tone =>
		outcome === 'delivered'
			? 'ok'
			: outcome === 'rejected'
				? 'err'
				: outcome === 'skipped' || outcome === 'retry' || outcome === 'dropped'
					? 'warn'
					: 'info';
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
		{#if !o.list.linkEnabled}
			<Panel>
				<EmptyState
					icon={SmartphoneIcon}
					title="Gerätekopplung ist ausgeschaltet"
					reason="Setze DEVICE_LINK_ENABLED=true und starte neu. Danach lässt sich in der App ein Gerät koppeln."
				/>
			</Panel>
		{:else}
			{#if o.list.devices.length === 0}
				<Panel>
					<EmptyState
						icon={SmartphoneIcon}
						title="Kein Gerät gekoppelt"
						reason="Aktiviere in der App unter Info den Schalter „Mit Dashboard koppeln“ und gib den angezeigten Code unten ein."
					/>
				</Panel>
			{/if}

			{#each o.list.devices as d (d.id)}
				{@const b = o.bundles[d.id]}
				<Panel
					title={d.label}
					description="Zuletzt gesehen {formatAgo(
						d.lastSeenAt,
						ctx.now
					)} · gekoppelt seit {formatDateTime(d.pairedAt)}{d.expiresAt
						? ` bis ${formatDateTime(d.expiresAt)}`
						: ''}"
				>
					<div class="mb-4 flex flex-wrap gap-2">
						<StatusBadge
							tone={tone(d.summary.level)}
							label={summaryText[d.summary.code] ?? d.summary.code}
						/>
						<StatusBadge tone="neutral" icon={false} label="APNs {d.env}" />
						{#if d.stale}<StatusBadge tone="warn" label="Länger nicht gesehen" />{/if}
					</div>

					{#if b}
						<h3 class="mb-2 text-[13px] font-semibold">
							Diagnose{#if b.diagnosis.verdict}<span class="text-muted-foreground ml-2 font-normal"
									>Befund: {checkName[b.diagnosis.verdict.code] ?? b.diagnosis.verdict.code} ({levelLabel[
										b.diagnosis.verdict.level
									].toLowerCase()})</span
								>{:else}<span class="text-muted-foreground ml-2 font-normal">alles in Ordnung</span
								>{/if}
						</h3>
						<ol class="divide-y rounded-lg border">
							{#each b.diagnosis.checks as c (c.order)}
								{@const t = tone(c.level)}
								{@const Icon = toneIcon[t]}
								<li class="flex items-start gap-3 px-3.5 py-3">
									<Icon class="mt-0.5 size-4 shrink-0 {toneText[t]}" aria-hidden="true" />
									<div class="min-w-0">
										<p class="text-sm font-medium">
											{c.order}. {checkName[c.code] ?? c.code}<span class="sr-only"
												>: {levelLabel[c.level]}</span
											>
										</p>
										<p class="text-muted-foreground text-[13px]">{checkText(c.code, c.reason)}</p>
									</div>
								</li>
							{/each}
						</ol>

						<h3 class="mt-5 mb-2 text-[13px] font-semibold">Installation und Abos</h3>
						<dl class="grid grid-cols-2 gap-x-6 gap-y-2 text-[13px] sm:grid-cols-4">
							<div>
								<dt class="text-muted-foreground">Geräte-Token</dt>
								<dd class="font-medium">
									{b.detail.installation.deviceToken.present
										? `vorhanden, ${b.detail.installation.deviceToken.ageDays ?? '–'} Tage alt`
										: 'fehlt'}
								</dd>
							</div>
							<div>
								<dt class="text-muted-foreground">Start-Token</dt>
								<dd class="font-medium">
									{b.detail.installation.startToken.present
										? `vorhanden, ${b.detail.installation.startToken.ageDays ?? '–'} Tage alt`
										: 'fehlt'}
								</dd>
							</div>
							<div>
								<dt class="text-muted-foreground">Live Activity</dt>
								<dd class="font-medium">
									{b.detail.activity.state === 'active'
										? `läuft seit ${formatAgo(b.detail.activity.startedAt, ctx.now).replace('vor ', '')}`
										: b.detail.activity.state === 'reserved'
											? 'reserviert'
											: 'keine'}
								</dd>
							</div>
							<div>
								<dt class="text-muted-foreground">Abos</dt>
								<dd class="font-medium">
									{b.detail.subscriptions.length} ({b.detail.subscriptions.filter(
										(s) => s.liveActivity
									).length} mit Live Activity)
								</dd>
							</div>
						</dl>
					{/if}

					<h3 class="mt-5 mb-2 text-[13px] font-semibold">Aktionen</h3>
					<div class="flex flex-wrap gap-2">
						{#each actions as a (a.key)}
							{@const Icon = a.icon}
							<Button
								variant={a.destructive ? 'ghost' : 'outline'}
								size="sm"
								class={a.destructive ? 'text-destructive hover:text-destructive' : ''}
								disabled={running === d.id}
								onclick={() => ask(d, a)}
							>
								<Icon aria-hidden="true" />{a.label}
							</Button>
						{/each}
					</div>
					{#if running === d.id}<p class="text-muted-foreground mt-2 text-[13px]" role="status">
							Auftrag läuft, Ergebnis folgt …
						</p>{/if}

					{#if b}
						<h3 class="mt-5 mb-2 text-[13px] font-semibold">Verlauf</h3>
						{#if b.events.length === 0}
							<p class="text-muted-foreground text-[13px]">
								Noch keine Ereignisse (Aufbewahrung 48 Stunden).
							</p>
						{:else}
							<ol class="relative ml-1.5 flex flex-col gap-4 border-l pl-5">
								{#each b.events as ev (ev.at + ev.kind)}
									{@const t = evTone(ev.outcome)}
									{@const Icon = toneIcon[t]}
									<li class="relative">
										<span
											class="bg-card absolute top-0.5 -left-[1.9rem] inline-flex size-5 items-center justify-center rounded-full"
										>
											<Icon class="size-4 {toneText[t]}" aria-hidden="true" />
										</span>
										<p class="text-sm font-medium">
											{eventKindName[ev.kind] ?? ev.kind}: {outcomeName[ev.outcome] ?? ev.outcome}
										</p>
										{#if ev.reason}<p class="text-muted-foreground text-[13px]">
												{eventReasonName[ev.reason] ?? ev.reason}
											</p>{/if}
										<p class="text-muted-foreground num text-[12px]">
											<time datetime={ev.at}>{formatDateTime(ev.at)}</time>
										</p>
									</li>
								{/each}
							</ol>
						{/if}
					{/if}
				</Panel>
			{/each}

			<Panel
				title="Gerät koppeln"
				description="{o.list.devices.length} von {o.list.max} Plätzen belegt."
				info="Der Code wird in der App angezeigt, gilt kurz und nur einmal. Es werden nur Zustände und Zähler gespeichert, keine Tokens oder Standorte."
			>
				{#if o.list.devices.length >= o.list.max}
					<p class="text-muted-foreground text-sm">
						Alle Plätze sind belegt. Widerrufe zuerst eine Kopplung.
					</p>
				{:else}
					<form
						onsubmit={pair}
						class="grid max-w-xl gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
					>
						<div class="space-y-1.5">
							<Label for="link-code">Koppelcode aus der App</Label>
							<Input
								id="link-code"
								bind:value={code}
								placeholder="ABCD-EFGH"
								autocomplete="off"
								autocapitalize="characters"
								spellcheck={false}
								class="font-mono tracking-widest"
								aria-describedby={formError ? 'link-err' : undefined}
								aria-invalid={formError ? true : undefined}
							/>
						</div>
						<div class="space-y-1.5">
							<Label for="link-label">Bezeichnung</Label>
							<Input
								id="link-label"
								bind:value={label}
								placeholder="Mein iPhone"
								maxlength={40}
								autocomplete="off"
							/>
						</div>
						<Button
							type="submit"
							disabled={linking || code.replace(/[\s-]/g, '').length < 8 || label.trim().length < 1}
							>{linking ? 'Prüfe …' : 'Koppeln'}</Button
						>
					</form>
					{#if formError}<p id="link-err" role="alert" class="text-destructive mt-2 text-[13px]">
							{formError}
						</p>{/if}
				{/if}
			</Panel>
		{/if}
	{/snippet}
</Loadable>

<ConfirmDialog
	bind:open
	title="{pending?.def.label ?? 'Aktion'}?"
	description={pending ? `${pending.device.label}: ${pending.def.consequence}` : ''}
	confirmLabel={pending?.def.label ?? 'Bestätigen'}
	destructive={pending?.def.destructive}
	{busy}
	onconfirm={run}
/>
