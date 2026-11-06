/**
 * Deutsche Texte zu den Fehlercodes des Vertrags (docs-site/content/dashboard-api.md).
 * Schluessel sind Servercodes ({"error":"<code>"}) oder die Fehlerklassen des Clients.
 */
export const errorText: Record<string, string> = {
	validation: 'Eingabe ungültig.',
	unauthorized: 'Sitzung abgelaufen oder Anmeldung abgelehnt.',
	forbidden: 'Nicht erlaubt.',
	setup_closed: 'Die Einrichtung ist geschlossen. Das Dashboard muss neu gestartet werden.',
	not_found: 'Nicht gefunden.',
	code_unknown: 'Code unbekannt, abgelaufen oder bereits verwendet.',
	device_limit: 'Alle Geräteplätze sind belegt.',
	link_disabled: 'Die Gerätekopplung ist ausgeschaltet (DEVICE_LINK_ENABLED).',
	push_leader_missing:
		'Kein Push-Leader aktiv: der Auftrag würde nicht ausgeführt. Später erneut versuchen.',
	push_disabled: 'Push ist ausgeschaltet; Aufträge werden nicht ausgeführt.',
	push_state_unknown:
		'Der Push-Zustand ist unbekannt: kein Radar-Replikat hat sich kürzlich gemeldet.',
	command_pending: 'Für dieses Gerät läuft bereits ein gleichartiger Auftrag.',
	action_rate_limited: 'Zu viele Aktionen in kurzer Zeit. Später erneut versuchen.',
	rate_limited: 'Zu viele Anfragen. Später erneut versuchen.',
	data_unavailable: 'Die Datenbank ist nicht erreichbar.',
	unavailable: 'Der Dienst ist vorübergehend nicht verfügbar.',
	conflict: 'Konflikt: Der Zustand hat sich geändert.',
	locked_by_env: 'Durch Umgebungsvariable festgelegt, im Dashboard nicht änderbar.',
	network: 'Der Server ist nicht erreichbar.',
	bad_response: 'Unerwartete Antwort des Servers.',
	unknown: 'Unbekannter Fehler.'
};
