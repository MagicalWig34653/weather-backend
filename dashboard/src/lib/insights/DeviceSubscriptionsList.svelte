<script lang="ts">
	import StatusBadge from '#lib/design/StatusBadge.svelte';
	import type { Tone } from '#lib/design/tone.js';
	import { ctx } from '#lib/design/context.svelte.js';
	import { formatAgo, formatDateTime, formatDuration } from '#lib/format.js';
	import {
		activityLabel,
		cellLabel,
		kindLabel,
		radarStatusLabel,
		subscriptionStateDetail,
		subscriptionStateLabel,
		thresholdText
	} from './text.js';
	import type { CellState, DeviceSubscriptions } from './types.js';

	let { data }: { data: DeviceSubscriptions } = $props();

	const cellTone = (c: CellState): Tone => (c === 'wet' ? 'info' : c === 'dry' ? 'ok' : 'neutral');
	const radarOk = $derived(data.radar.status === 'ok');
	/** Sperre noch aktiv? */
	const locked = (iso: string | null): boolean => !!iso && Date.parse(iso) > ctx.now;
</script>

{#if !radarOk}
	<p class="bg-warn-soft text-warn mb-3 rounded-lg px-3 py-2 text-[13px]" role="status">
		{radarStatusLabel(data.radar.status)}{data.radar.runAgeSeconds !== null
			? ` (Lauf ${formatDuration(data.radar.runAgeSeconds)} alt)`
			: ''}: Die aktuelle Intensität der Zellen ist deshalb unbekannt.
	</p>
{/if}

{#if data.subscriptions.length === 0}
	<p class="text-muted-foreground text-[13px]">
		Dieses Gerät hat keine Abos. Orte, Umkreise und Live Activities werden in der App angelegt.
	</p>
{:else}
	<ul class="grid gap-3 lg:grid-cols-2">
		{#each data.subscriptions as s (s.index)}
			<li class="bg-background rounded-lg border p-3.5">
				<div class="flex flex-wrap items-center gap-2">
					<h4 class="text-sm font-semibold">Abo {s.index + 1}: {kindLabel(s.kind)}</h4>
					<StatusBadge
						tone={s.enabled ? 'ok' : 'neutral'}
						label={s.enabled ? 'Aktiv' : 'Ausgeschaltet'}
					/>
					{#if s.liveActivity}<StatusBadge tone="info" icon={false} label="Live Activity" />{/if}
					{#if s.timeSensitive}<StatusBadge tone="neutral" icon={false} label="Zeitkritisch" />{/if}
				</div>
				<dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 text-[13px]">
					<div>
						<dt class="text-muted-foreground">Auslöser</dt>
						<dd class="font-medium">
							ab {thresholdText(s.thresholdClass)}, {s.leadMinutes} min Vorlauf
						</dd>
					</div>
					{#if s.kind === 'circle'}
						<div>
							<dt class="text-muted-foreground">Umkreis</dt>
							<dd class="font-medium">
								{s.radiusCells ?? '–'} Zellen, ab {s.minSharePercent ?? '–'} % betroffen
							</dd>
						</div>
					{/if}
					<div class="col-span-2 sm:col-span-1">
						<dt class="text-muted-foreground">Zustand</dt>
						<dd class="font-medium">
							{subscriptionStateLabel(s.state)}
							{#if s.hysteresis}<span class="text-muted-foreground font-normal">
									· Regen gesehen (Hysterese)</span
								>{/if}
						</dd>
						<dd class="text-muted-foreground text-[12px]">{subscriptionStateDetail(s.state)}</dd>
					</div>
					<div>
						<dt class="text-muted-foreground">Zelle jetzt</dt>
						<dd>
							<StatusBadge tone={cellTone(s.cell)} label={cellLabel(s.cell)} />
						</dd>
					</div>
					<div>
						<dt class="text-muted-foreground">Im Vorlauf</dt>
						<dd>
							<StatusBadge tone={cellTone(s.leadCell)} label={cellLabel(s.leadCell)} />
							{#if s.leadCell === 'wet' && s.state === 'dry'}<span
									class="text-muted-foreground block text-[12px]">würde auslösen</span
								>{/if}
						</dd>
					</div>
					<div>
						<dt class="text-muted-foreground">Letzter Versand</dt>
						<dd class="font-medium num">
							{#if s.lastSentAt}<time datetime={s.lastSentAt}>{formatDateTime(s.lastSentAt)}</time>
								<span class="text-muted-foreground font-normal"
									>({formatAgo(s.lastSentAt, ctx.now)})</span
								>{:else}noch nie{/if}
						</dd>
					</div>
					<div>
						<dt class="text-muted-foreground">Gesperrt bis</dt>
						<dd class="font-medium num">
							{#if s.lockUntil && locked(s.lockUntil)}<time datetime={s.lockUntil}
									>{formatDateTime(s.lockUntil)}</time
								>{:else}nicht gesperrt{/if}
						</dd>
					</div>
					{#if s.liveActivity || s.activity !== 'none'}
						<div class="col-span-2">
							<dt class="text-muted-foreground">Live-Activity-Platz</dt>
							<dd class="font-medium">{activityLabel(s.activity)}</dd>
						</div>
					{/if}
				</dl>
			</li>
		{/each}
	</ul>
{/if}
