<script lang="ts">
	import { Popover } from 'bits-ui';
	import LogOutIcon from '@lucide/svelte/icons/log-out';
	import KeyRoundIcon from '@lucide/svelte/icons/key-round';
	import { session } from '#lib/session.svelte.js';
	import { formatDateTime } from '#lib/format.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import StatusDot from '../StatusDot.svelte';
	import ThemeSwitch from './ThemeSwitch.svelte';

	const cred = $derived(session.state?.state === 'authenticated' ? session.state.credential : null);
</script>

<Popover.Root>
	<Popover.Trigger
		aria-label="Sitzung und Darstellung"
		class="hover:bg-muted inline-flex h-9 items-center gap-2 rounded-lg pr-2 pl-1 transition-colors"
	>
		<span
			class="bg-primary-soft text-primary-ink inline-flex size-7 items-center justify-center rounded-full text-xs font-semibold"
			aria-hidden="true">B</span
		>
		<span class="hidden text-[13px] font-medium sm:inline">Betreiber</span>
	</Popover.Trigger>
	<Popover.Portal>
		<Popover.Content
			align="end"
			sideOffset={8}
			collisionPadding={12}
			class="bg-popover text-popover-foreground shadow-pop fade-in z-50 w-72 rounded-xl border p-4"
		>
			<div class="flex items-center gap-3">
				<span
					class="bg-primary-soft text-primary-ink inline-flex size-10 items-center justify-center rounded-full"
				>
					<KeyRoundIcon class="size-5" aria-hidden="true" />
				</span>
				<div class="min-w-0">
					<p class="truncate text-sm font-medium">{cred?.name ?? 'Passkey'}</p>
					<p class="text-muted-foreground flex items-center gap-1.5 text-[12px]">
						<StatusDot tone="ok" /> Angemeldet per Passkey
					</p>
				</div>
			</div>
			{#if cred}
				<p class="text-muted-foreground mt-3 text-[12px]">
					Passkey registriert am <time datetime={cred.createdAt}
						>{formatDateTime(cred.createdAt)}</time
					>. Stammt das nicht von dir, setze den Zugang mit dem Notfall-Befehl zurück.
				</p>
			{/if}
			<div class="mt-4 flex items-center justify-between gap-3">
				<span class="text-[13px] font-medium">Darstellung</span>
				<ThemeSwitch />
			</div>
			<Button variant="outline" class="mt-4 w-full" onclick={() => session.logout()}>
				<LogOutIcon aria-hidden="true" /> Abmelden
			</Button>
		</Popover.Content>
	</Popover.Portal>
</Popover.Root>
