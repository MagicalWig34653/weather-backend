<script lang="ts">
	import { api } from '#lib/client.js';
	import { ApiError, type SessionState } from '#lib/api.js';
	import { authErrorText } from '#lib/auth-errors.js';
	import { createPasskey, getPasskey, passkeysSupported } from '#lib/passkey.js';
	import { session } from '#lib/session.svelte.js';
	import * as Alert from '#lib/components/ui/alert/index.js';
	import { Button } from '#lib/components/ui/button/index.js';
	import * as Card from '#lib/components/ui/card/index.js';
	import { asset } from '$app/paths';
	import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';

	let { mode }: { mode: Extract<SessionState, { state: 'setupOpen' | 'setupClosed' | 'login' }> } =
		$props();

	let busy = $state(false);
	let error = $state<string | null>(null);

	const supported = $derived(__MOCK__ || passkeysSupported());
	const isSetup = $derived(mode.state === 'setupOpen');

	async function run(): Promise<void> {
		busy = true;
		error = null;
		try {
			if (isSetup) {
				const begin = await api.setupBegin();
				const cred = __MOCK__ ? await mockCred() : await createPasskey(begin.options);
				await api.setupFinish(begin.challengeId, cred);
			} else {
				const begin = await api.loginBegin();
				const cred = __MOCK__ ? await mockCred() : await getPasskey(begin.options);
				await api.loginFinish(begin.challengeId, cred as never);
			}
			await session.refresh();
		} catch (e) {
			error = authErrorText(e, isSetup);
			// Fenster/Passkey-Zustand hat sich geaendert: Sitzungszustand neu laden.
			if (e instanceof ApiError && (e.code === 'conflict' || e.serverCode === 'setup_closed'))
				void session.refresh();
		} finally {
			busy = false;
		}
	}

	// Nur im Mock-Build vorhanden (Literalkonstante, im Produktionsbuild entfernt).
	async function mockCred() {
		return (await import('#lib/mock-passkey.js')).mockCredential();
	}
</script>

<div class="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 p-4">
	<Card.Root>
		<Card.Header>
			<img
				src={asset('icons/icon-64.png')}
				srcset="{asset('icons/icon-64.png')} 1x, {asset('icons/icon-192.png')} 3x"
				alt=""
				width="56"
				height="56"
				class="mb-2 size-14 rounded-[22%]"
			/>
			<Card.Title class="text-xl">
				{mode.state === 'setupClosed'
					? 'Dashboard gesperrt'
					: isSetup
						? 'Dashboard einrichten'
						: 'Anmelden'}
			</Card.Title>
			<Card.Description>
				{isSetup
					? 'Registriere jetzt den Passkey für den Betreiber. Danach schließt sich die Einrichtung.'
					: 'Melde dich mit dem Passkey des Betreibers an.'}
			</Card.Description>
		</Card.Header>
		<Card.Content class="space-y-4">
			{#if mode.state === 'setupClosed'}
				<Alert.Root variant="destructive">
					<TriangleAlertIcon aria-hidden="true" />
					<Alert.Title>Einrichtung geschlossen</Alert.Title>
					<Alert.Description>
						Es gibt noch keinen Passkey, und das Einrichtungsfenster ist abgelaufen. Starte das
						Dashboard neu, um es wieder zu öffnen.
					</Alert.Description>
				</Alert.Root>
			{:else if mode.state === 'setupOpen'}
				<Alert.Root variant="destructive">
					<TriangleAlertIcon aria-hidden="true" />
					<Alert.Title>Einrichtung ist offen</Alert.Title>
					<Alert.Description>
						Noch etwa {mode.minutesLeft} Minuten kann ohne Token ein erster Passkey registriert werden.
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
			<Button
				class="w-full"
				size="lg"
				onclick={run}
				disabled={busy || !supported || mode.state === 'setupClosed'}
			>
				{#if busy}Warte auf Passkey …{:else if isSetup}Passkey registrieren{:else}Mit Passkey
					anmelden{/if}
			</Button>
		</Card.Content>
	</Card.Root>
	<p class="text-muted-foreground text-center text-xs">Showers Dashboard · nur für den Betreiber</p>
</div>
