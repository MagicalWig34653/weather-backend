<script lang="ts">
	import { api } from '#lib/client.js';
	import { ApiError, type SessionState } from '#lib/api.js';
	import { MOCK } from '#lib/client.js';
	import { createPasskey, getPasskey, passkeysSupported, PasskeyError } from '#lib/passkey.js';
	import { session } from '#lib/session.svelte.js';
	import * as Alert from '#lib/components/ui/alert/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import LockIcon from '@lucide/svelte/icons/lock-keyhole';
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';

	let { mode }: { mode: Extract<SessionState, { state: 'setup_open' | 'login' }> } = $props();

	let busy = $state(false);
	let error = $state<string | null>(null);

	const supported = $derived(MOCK || passkeysSupported());
	const isSetup = $derived(mode.state === 'setup_open');

	async function run(): Promise<void> {
		busy = true;
		error = null;
		try {
			if (isSetup) {
				const begin = await api.setupBegin();
				const cred = MOCK ? mockCred() : await createPasskey(begin.options);
				await api.setupFinish(begin.challenge_id, cred);
			} else {
				const begin = await api.loginBegin();
				const cred = MOCK ? mockCred() : await getPasskey(begin.options);
				await api.loginFinish(begin.challenge_id, cred as never);
			}
			await session.refresh();
		} catch (e) {
			if (e instanceof PasskeyError) error = e.message;
			else if (e instanceof ApiError) {
				error =
					e.code === 'conflict'
						? 'Die Einrichtung ist bereits abgeschlossen. Seite neu laden.'
						: e.code === 'rate_limited'
							? 'Zu viele Versuche. Bitte eine Minute warten.'
							: e.code === 'unauthorized' || e.code === 'validation'
								? 'Anmeldung abgelehnt. Bitte erneut versuchen.'
								: e.message;
			} else error = 'Unbekannter Fehler.';
		} finally {
			busy = false;
		}
	}

	function mockCred() {
		return {
			id: 'mock',
			rawId: 'mock',
			type: 'public-key' as const,
			response: { clientDataJSON: '', attestationObject: '' }
		};
	}
</script>

<div class="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 p-4">
	<Card.Root>
		<Card.Header>
			<div
				class="bg-primary/10 text-primary mb-2 flex size-10 items-center justify-center rounded-full"
			>
				<LockIcon class="size-5" aria-hidden="true" />
			</div>
			<Card.Title class="text-xl">
				{isSetup ? 'Dashboard einrichten' : 'Anmelden'}
			</Card.Title>
			<Card.Description>
				{isSetup
					? 'Registriere jetzt den Passkey für den Betreiber. Danach schließt sich die Einrichtung.'
					: 'Melde dich mit dem Passkey des Betreibers an.'}
			</Card.Description>
		</Card.Header>
		<Card.Content class="space-y-4">
			{#if mode.state === 'setup_open'}
				<Alert.Root variant="destructive">
					<TriangleAlertIcon aria-hidden="true" />
					<Alert.Title>Einrichtung ist offen</Alert.Title>
					<Alert.Description>
						Noch etwa {mode.minutes_left} Minuten kann ohne Token ein erster Passkey registriert werden.
						Wer zuerst kommt, wird Betreiber. Nur fortfahren, wenn du es selbst bist.
					</Alert.Description>
				</Alert.Root>
			{/if}
			{#if !supported}
				<Alert.Root variant="destructive">
					<Alert.Title>Passkeys nicht verfügbar</Alert.Title>
					<Alert.Description>
						Dieser Browser oder diese Verbindung unterstützt keine Passkeys. Das Dashboard muss über
						HTTPS aufgerufen werden.
					</Alert.Description>
				</Alert.Root>
			{/if}
			{#if error}
				<div role="alert" class="text-destructive text-sm">{error}</div>
			{/if}
			<Button class="w-full" size="lg" onclick={run} disabled={busy || !supported}>
				{#if busy}Warte auf Passkey …{:else if isSetup}Passkey registrieren{:else}Mit Passkey
					anmelden{/if}
			</Button>
		</Card.Content>
	</Card.Root>
	<p class="text-muted-foreground text-center text-xs">Showers Dashboard · nur für den Betreiber</p>
</div>
