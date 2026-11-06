/**
 * Deutsche Texte zu den Codes des Vertrags: Der Server sendet nur Codes und Parameter.
 * Unbekannte Codes erscheinen unveraendert (Vertrag: offene Aufzaehlungen).
 */
import { formatDuration, formatNumber, formatPercent } from '#lib/format.js';
import type { Tone } from '#lib/design/tone.js';
import type { Finding, Level } from './types.js';

export const levelTone = (l: Level): Tone =>
	l === 'ok' ? 'ok' : l === 'warning' ? 'warn' : l === 'critical' ? 'err' : 'neutral';
export const levelLabel: Record<Level, string> = {
	ok: 'In Ordnung',
	warning: 'Warnung',
	critical: 'Kritisch',
	unknown: 'Unbekannt'
};

const layerNames: Record<string, string> = {
	radar: 'Niederschlagsradar',
	pressure: 'Luftdruck',
	pressure_eu: 'Luftdruck (Europa)',
	lightning: 'Blitze',
	clouds: 'Wolken',
	cloudmask: 'Wolkenmaske',
	cloudmask_vis: 'Wolkenmaske (sichtbar)',
	cloudmask_vis_eu: 'Wolkenmaske (sichtbar, Europa)'
};
export const layerName = (id: string): string => layerNames[id] ?? id;

const capNames: Record<string, string> = {
	installations: 'Installationen',
	subscriptions: 'Abos',
	region_cells: 'Regionszellen',
	activity_subscriptions: 'Live-Activity-Abos'
};
export const capName = (k: string): string => capNames[k] ?? k;

function fmt(unit: Finding['unit'], v: number): string {
	return unit === 'ratio'
		? formatPercent(v)
		: unit === 'seconds'
			? formatDuration(v)
			: unit === 'percent'
				? `${formatNumber(v)} %`
				: formatNumber(v);
}

/** Titel und Erklaerung eines Befunds. */
export function findingText(f: Finding): { title: string; detail: string } {
	const v = fmt(f.unit, f.value);
	const th = fmt(f.unit, f.threshold);
	const over = `Aktuell ${v}, Schwelle ${th}.`;
	switch (f.code) {
		case 'layer_stale':
			return {
				title: `${layerName(f.subject ?? '')}: Ebene veraltet`,
				detail: `Der letzte Stand ist ${v} alt (Schwelle ${th}). Prüfe die Aufnahme-Läufe im Betrieb.`
			};
		case 'error_rate_5xx':
			return { title: 'Hohe Fehlerquote (5xx)', detail: over };
		case 'outbox_age':
			return {
				title: 'Warteschlange staut sich',
				detail: `Ältester Eintrag ${v} alt (Schwelle ${th}).`
			};
		case 'apns_rejection':
			return { title: 'APNs lehnt viele Sendungen ab', detail: over };
		case 'token_invalidation':
			return { title: 'Viele ungültige Token', detail: over };
		case 'replicas_missing':
			return { title: 'Replikate fehlen', detail: `${v} gemeldet, erwartet ${th}.` };
		case 'leader_missing':
			return {
				title: 'Kein Versand-Leader',
				detail: 'Es hält kein Replikat die Leader-Sperre; es wird nichts gesendet.'
			};
		case 'cache_hit_low':
			return { title: 'Cache-Quote niedrig', detail: `${v} Treffer, Untergrenze ${th}.` };
		case 'cap_fill':
			return {
				title: `${capName(f.subject ?? '')}: Grenze fast erreicht`,
				detail: `Füllgrad ${v} (Schwelle ${th}).`
			};
		case 'la_start_ratio_low':
			return {
				title: 'Live Activities starten selten',
				detail: `Nur ${v} der möglichen Starts gelingen (Untergrenze ${th}).`
			};
		default:
			return { title: f.code, detail: over };
	}
}

/** Ziel-Seite eines Befunds. */
export function findingHref(f: Finding): string {
	if (
		f.code === 'layer_stale' ||
		f.code === 'error_rate_5xx' ||
		f.code === 'cache_hit_low' ||
		f.code === 'replicas_missing' ||
		f.code === 'leader_missing'
	)
		return '/betrieb';
	if (f.code === 'cap_fill') return '/abos';
	return '/push';
}

export const routeName: Record<string, string> = {
	healthz: 'Health-Check',
	status: 'Status',
	radar_latest: 'Radar, neueste Aufnahme',
	radar_history: 'Radar, Verlauf',
	radar_image: 'Radar, Bild',
	layer_manifest: 'Ebene, Manifest',
	layer_image: 'Ebene, Bild',
	push: 'Push-API',
	landing: 'Startseite',
	asset: 'Dateien',
	site_page: 'Textseiten',
	dash_api: 'Dashboard-API',
	dash_static: 'Dashboard-Dateien',
	other: 'Sonstige'
};
export const routeLabel = (r: string): string => routeName[r] ?? r;

export const pageName: Record<string, string> = {
	landing_de: 'Startseite (de)',
	landing_en: 'Startseite (en)',
	privacy: 'Datenschutz',
	marketing: 'Marketing',
	support: 'Support'
};

export const triggerName: Record<string, string> = {
	rain_start: 'Regen beginnt',
	raining_now: 'Es regnet',
	la_rain_start: 'Live Activity, Regen beginnt',
	la_raining_now: 'Live Activity, es regnet',
	run: 'Ganzer Lauf'
};
export const skipName: Record<string, string> = {
	lock_60min: 'Sperrzeit (60 Minuten)',
	hysteresis: 'Hysterese',
	no_start_token: 'Start-Token fehlt',
	activity_slot_busy: 'Platz belegt (Live Activity läuft)',
	reservation_pending: 'Reservierung offen',
	not_enabled: 'Abo nicht aktiviert',
	budget_exhausted: 'Budget erschöpft',
	below_threshold: 'Unter der Schwelle',
	env_not_allowed: 'APNs-Umgebung nicht erlaubt',
	unknown_pixel: 'Unbekannter Bildpunkt',
	no_fresh_run: 'Kein frischer Radarlauf',
	incomplete_run: 'Unvollständiger Radarlauf',
	paused: 'Push pausiert'
};
export const eventName: Record<string, string> = {
	start: 'Start',
	update: 'Aktualisierung',
	end: 'Ende',
	expire: 'Ablauf'
};
export const outcomeName: Record<string, string> = {
	delivered: 'zugestellt',
	rejected: 'abgelehnt',
	retry: 'Wiederholung',
	dropped: 'verworfen',
	skipped: 'übersprungen'
};
export const rejectName: Record<string, string> = {
	server_full: 'Server voll',
	activity_full: 'Live-Activity-Plätze voll',
	region_limit: 'Regionsgrenze',
	subscription_limit: 'Abo-Grenze',
	start_token_required: 'Start-Token erforderlich',
	unauthorized: 'Nicht autorisiert'
};
export const invalidationName: Record<string, string> = {
	device: 'Geräte-Token',
	start: 'Start-Token',
	activity: 'Aktivitäts-Token'
};
export const causeName: Record<string, string> = {
	'410': 'HTTP 410',
	bad_device_token: 'BadDeviceToken',
	other: 'Sonstige'
};
export const apnsKindName: Record<string, string> = {
	alert: 'Mitteilung',
	start: 'Live-Activity-Start',
	update: 'Live-Activity-Update',
	end: 'Live-Activity-Ende'
};

export const prerequisiteName: Record<string, string> = {
	push_enabled: 'Push ist aktiviert',
	apns_env_match: 'APNs-Umgebung passt zu den Installationen',
	apns_topic_set: 'APNs-Topic gesetzt',
	apns_key_present: 'APNs-Schlüssel vorhanden',
	capability_live_activity: 'Live-Activity-Fähigkeit aktiv',
	push_not_paused: 'Versand nicht pausiert'
};
export const prerequisiteDetail: Record<string, string> = {
	sandbox_install_with_production_env:
		'Es gibt Sandbox-Installationen, APNs läuft aber mit production: sie erhalten nichts.',
	production_install_with_sandbox_env:
		'Es gibt Produktiv-Installationen, APNs läuft aber mit sandbox: sie erhalten nichts.'
};

export const checkName: Record<string, string> = {
	server: 'Server',
	environment: 'Umgebung',
	device_token: 'Geräte-Token',
	start_token: 'Start-Token',
	subscription: 'Abo',
	slot: 'Platz',
	lock: 'Sperre',
	trigger: 'Auslösung',
	last_result: 'Letztes Ergebnis'
};
const checkReason: Record<string, Record<string, string>> = {
	server: {
		ok: 'Push ist aktiv.',
		push_disabled: 'Push ist am Server abgeschaltet (PUSH_ENABLED).',
		capability_missing: 'Die Live-Activity-Fähigkeit ist nicht aktiviert.',
		push_paused: 'Der Versand ist pausiert.'
	},
	environment: {
		ok: 'Installation und Server nutzen dieselbe APNs-Umgebung.',
		env_not_allowed: 'Die Umgebung der Installation ist am Server nicht erlaubt (APNS_ENV).'
	},
	device_token: {
		ok: 'Gültiger Geräte-Token.',
		missing: 'Es wurde noch kein Geräte-Token gemeldet.',
		old: 'Der Geräte-Token ist alt; die App meldet sich lange nicht.',
		invalidated_recently: 'APNs hat den Token kürzlich als ungültig gemeldet.'
	},
	start_token: {
		ok: 'Start-Token vorhanden.',
		missing:
			'Es wurde noch kein Live-Activity-Start-Token gemeldet. Die App im Vordergrund öffnen.',
		old: 'Der Start-Token ist alt.'
	},
	subscription: {
		ok: 'Abo mit Live Activity vorhanden.',
		no_subscription: 'Es gibt kein Abo.',
		disabled: 'Das Abo ist ausgeschaltet.',
		live_activity_off: 'Live Activity ist im Abo ausgeschaltet.'
	},
	slot: {
		ok: 'Platz frei.',
		reservation_open: 'Eine Reservierung ist offen und blockiert den Platz.',
		activity_running: 'Eine Live Activity läuft bereits.'
	},
	lock: {
		ok: 'Keine Sperre aktiv.',
		lock_active: 'Die 60-Minuten-Sperre ist aktiv.',
		hysteresis: 'Die Hysterese verhindert einen erneuten Start.'
	},
	trigger: {
		would_trigger: 'Die Auswertung würde jetzt auslösen.',
		below_threshold: 'Aktuell liegt der Niederschlag unter der Schwelle.',
		no_slot: 'Es ist kein Platz frei.',
		stale_run: 'Der letzte Radar-Lauf ist zu alt für eine Auswertung.'
	},
	last_result: {
		none: 'Noch kein Versand.',
		delivered: 'Der letzte Versand wurde zugestellt.',
		rejected: 'Der letzte Versand wurde abgelehnt.',
		unregistered: 'APNs meldet das Gerät als abgemeldet.',
		retry: 'Der letzte Versand wird wiederholt.',
		dropped: 'Der letzte Versand wurde verworfen.'
	}
};
export const checkText = (code: string, reason: string): string =>
	checkReason[code]?.[reason] ?? `${code}: ${reason}`;

export const summaryText: Record<string, string> = {
	ok: 'Alles in Ordnung',
	no_start_token: 'Start-Token fehlt',
	no_device_token: 'Geräte-Token fehlt',
	env_mismatch: 'Umgebung passt nicht',
	no_live_activity_sub: 'Kein Live-Activity-Abo',
	unknown: 'Unbekannt'
};
export const eventKindName: Record<string, string> = {
	alert: 'Mitteilung',
	la_start: 'Live Activity gestartet',
	la_update: 'Live Activity aktualisiert',
	la_end: 'Live Activity beendet',
	test: 'Testpush',
	probe: 'Live-Activity-Test',
	token: 'Token geändert'
};
export const eventReasonName: Record<string, string> = { ...skipName };

/** Fehlercodes des Servers als Klartext. */
export { errorText } from '#lib/errors.js';

/** Entscheidung der Neuauswertung je Abo (Vertrag: Ergebnisform `reeval`). */
export const decisionName: Record<string, string> = {
	would_trigger: 'würde auslösen',
	below_threshold: 'unter der Schwelle',
	lock: 'gesperrt (60-Minuten-Sperre)',
	hysteresis: 'Hysterese aktiv',
	not_enabled: 'nicht aktiviert',
	no_start_token: 'Start-Token fehlt',
	activity_slot_busy: 'Platz belegt',
	reservation_pending: 'Reservierung offen'
};

export const commandKindName: Record<string, string> = {
	test: 'Testpush',
	la_probe: 'Live-Activity-Test',
	la_end: 'Live Activity beenden',
	reeval: 'Neuauswertung',
	reset_slot: 'Platz freigeben'
};
export const commandStatusName: Record<string, string> = {
	queued: 'wartet',
	running: 'läuft',
	done: 'erledigt',
	failed: 'fehlgeschlagen',
	expired: 'nicht ausgeführt'
};

/** Fehlercodes eines fehlgeschlagenen Auftrags (`error` bei status `failed`). */
export const commandErrorName: Record<string, string> = {
	apns_unavailable: 'APNs war nicht erreichbar.',
	environment_not_allowed: 'Die APNs-Umgebung des Geräts ist auf diesem Server nicht erlaubt.',
	device_gone: 'Die Installation ist inzwischen gelöscht.',
	internal: 'Interner Fehler im Versandpfad.'
};

/** Kurztext zum Ergebnis eines abgeschlossenen Geraete-Auftrags. */
export function commandResultText(kind: string, r: Record<string, unknown> | null): string {
	if (!r) return 'Erledigt.';
	const outcome = typeof r.outcome === 'string' ? (outcomeName[r.outcome] ?? r.outcome) : null;
	switch (kind) {
		case 'test':
			return outcome === 'zugestellt'
				? `Testpush von APNs angenommen (HTTP ${r.apnsStatus ?? '–'}).`
				: `Testpush ${outcome ?? 'ohne Ergebnis'}${r.reason ? `: ${r.reason}` : ''}.`;
		case 'la_probe':
			return r.skipped
				? `Nicht gesendet: ${skipName[String(r.skipped)] ?? r.skipped}.`
				: `Live-Activity-Test ${outcome ?? 'ohne Ergebnis'}${r.reason ? `: ${r.reason}` : ''}.`;
		case 'la_end':
			return r.hadActivity
				? `Live Activity beendet (${outcome ?? '–'}).`
				: 'Es lief keine Live Activity.';
		case 'reeval': {
			const subs =
				(r.subscriptions as
					{ index?: number; decision: string; sent?: boolean | null }[] | undefined) ?? [];
			const text = subs
				.map(
					(s, i) =>
						`Abo ${(s.index ?? i) + 1}: ${decisionName[s.decision] ?? s.decision}${s.sent === true ? ' (gesendet)' : ''}`
				)
				.join(' · ');
			return `${r.dryRun ? 'Trockenlauf' : 'Neuauswertung'}: ${text || 'keine Abos'}.`;
		}
		case 'reset_slot':
			return r.cleared === 'none'
				? 'Der Platz war bereits frei.'
				: `Platz freigegeben (${r.cleared === 'reservation' ? 'Reservierung' : 'Live Activity'}).`;
		default:
			return 'Erledigt.';
	}
}
