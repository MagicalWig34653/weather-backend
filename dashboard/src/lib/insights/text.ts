/**
 * Deutsche Texte zu den Codes des Vertrags: Der Server sendet nur Codes und Parameter.
 * Unbekannte Codes erscheinen unveraendert (Vertrag: offene Aufzaehlungen).
 */
import { formatDateTime, formatDuration, formatNumber, formatPercent } from '#lib/format.js';
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
				detail: `Seit ${v} sind keine neuen Daten eingetroffen (Schwelle ${th}). Die Karten dieser Ebene gelten als veraltet oder ausgefallen. Die Cache-Seite zeigt Nominalzeit des letzten Laufs, Takt und Fehlversuche.`
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
		case 'stats_hourly_empty':
			return {
				title: 'Stundenzähler noch nicht erfasst',
				detail: `Heute gibt es ${v} Anfragen in den Tageszählern, aber keine in den Stundenzählern. Diagramme zeigen deshalb Tageswerte; prüfe die Statistik-Schreibvorgänge im Betrieb.`
			};
		case 'stats_write_error':
			return {
				title: 'Statistik-Schreibfehler',
				detail: `${v} fehlgeschlagene Schreibvorgänge der Zähler in den letzten 24 Stunden (Tag oder Stunde). Die Zähler werden weiter versucht; Details im Dienstprotokoll (Zeile „statistics flush failed“).`
			};
		default:
			return { title: f.code, detail: over };
	}
}

/** Ziel-Seite eines Befunds. */
export function findingHref(f: Finding): string {
	if (f.code === 'layer_stale') return `/cache?layer=${encodeURIComponent(f.subject ?? 'radar')}`;
	if (
		f.code === 'error_rate_5xx' ||
		f.code === 'cache_hit_low' ||
		f.code === 'replicas_missing' ||
		f.code === 'leader_missing' ||
		f.code === 'stats_write_error'
	)
		return '/betrieb';
	if (f.code === 'cap_fill') return '/abos';
	if (f.code === 'stats_hourly_empty') return '/traffic';
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
	unknown: 'Unbekannt: kein Radar-Replikat hat sich kürzlich gemeldet.',
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
		push_unknown: 'Push-Zustand unbekannt: kein Radar-Replikat hat sich kürzlich gemeldet.',
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

/** Fehlertexte des Kopplungsfensters (haben Vorrang vor den allgemeinen Texten). */
export const pairingErrorText: Record<string, string> = {
	validation: 'Ungültige Dauer. Erlaubt sind 1 bis 15 Minuten.',
	unauthorized: 'Sitzung abgelaufen. Bitte neu anmelden.',
	rate_limited: 'Das Kopplungsfenster wurde zu oft geöffnet oder geschlossen.',
	link_disabled: 'Die Gerätekopplung ist ausgeschaltet (DEVICE_LINK_ENABLED).',
	not_found: 'Das Kopplungsfenster ist auf diesem Server nicht verfügbar.'
};

/** Entscheidung der Neuauswertung je Abo (Vertrag: Ergebnisform `reeval`). */
export const decisionName: Record<string, string> = {
	would_trigger: 'würde auslösen',
	below_threshold: 'unter der Schwelle',
	lock: 'gesperrt (60-Minuten-Sperre)',
	hysteresis: 'Hysterese aktiv',
	not_enabled: 'nicht aktiviert',
	no_start_token: 'Start-Token fehlt',
	activity_slot_busy: 'Platz belegt',
	reservation_pending: 'Reservierung offen',
	radar_stale: 'Radarlauf zu alt',
	radar_missing: 'kein Radarlauf'
};

/** Untere Grenzen der Intensitaetsklassen 1 bis 15 in mm/h (DWD-Legende `dwd:Niederschlagsradar`). */
export const classLowerMm = [0.1, 0.2, 0.4, 1, 2, 3, 5, 7.5, 10, 15, 30, 45, 75, 100, 150];
const mmText = (n: number): string => String(n).replace('.', ',');
/** "Klasse 3 (ab 0,4 mm/h)"; Klasse 0 heisst trocken. */
export function classText(c: number): string {
	if (c <= 0) return 'Klasse 0 (trocken)';
	return `Klasse ${c} (ab ${mmText(classLowerMm[Math.min(c, 15) - 1])} mm/h)`;
}

/** Ergebnisgrund der Neuauswertung (feste Woerter, siehe Vertrag `reeval`). */
export const reasonName: Record<string, string> = {
	would_trigger: 'Schwelle erreicht, würde auslösen',
	lock: '60-Minuten-Sperre aktiv',
	hysteresis: 'Regen schon gesehen, wartet auf trockene Phase (Hysterese)',
	not_enabled: 'Abo ist ausgeschaltet',
	no_start_token: 'Start-Token fehlt',
	activity_slot_busy: 'Live-Activity-Platz belegt',
	reservation_pending: 'Reservierung noch offen',
	cell_dry: 'Zelle trocken',
	class_below_threshold: 'Regen im Radar, aber unter der Schwelle',
	pixel_unknown: 'Pixel unbekannt (maskiert oder Farbe außerhalb der Legende)',
	share_below: 'zu wenig nasse Zellen im Umkreis',
	already_wet: 'Regen läuft schon (Mitteilung nur beim Beginn)',
	radar_stale: 'Lauf zu alt',
	radar_missing: 'kein vollständiger Radarlauf'
};

interface MeasureLike {
	reason?: string;
	decision?: string;
	thresholdClass?: number;
	minSharePercent?: number | null;
	kind?: string;
	measuredClass?: number | null;
	leadMaxClass?: number | null;
	leadOnsetMinutes?: number | null;
	wetCells?: number | null;
	cells?: number | null;
	neededCells?: number | null;
	sharePercent?: number | null;
}

/** Messung eines Abos als Klartext: gemessene Klasse gegen Schwelle, bei Umkreisen Anteil. */
export function measureText(m: MeasureLike): string {
	const parts: string[] = [];
	if (m.measuredClass === null || m.measuredClass === undefined) {
		if (m.reason === 'pixel_unknown') parts.push('Pixel unbekannt');
		else parts.push('keine Messung');
	} else {
		const label = m.kind === 'circle' ? 'im Umkreis höchstens' : 'jetzt';
		parts.push(`${label}: ${classText(m.measuredClass)}`);
	}
	if (m.thresholdClass !== undefined) parts.push(`Schwelle: ${classText(m.thresholdClass)}`);
	if (m.kind === 'circle' && m.wetCells !== null && m.wetCells !== undefined && m.cells) {
		const share = m.sharePercent ?? 0;
		parts.push(
			`Anteil ${String(share).replace('.', ',')} % (${m.wetCells} von ${m.cells} Zellen, nötig ${m.neededCells ?? '–'}) gegen ${m.minSharePercent ?? '–'} %`
		);
	}
	if (m.leadMaxClass !== null && m.leadMaxClass !== undefined)
		parts.push(
			m.leadOnsetMinutes
				? `im Vorlauf erreicht in ${m.leadOnsetMinutes} min`
				: `im Vorlauf höchstens ${classText(m.leadMaxClass)}`
		);
	return parts.join(' · ');
}

/** Zeile zum ausgewerteten Lauf der Neuauswertung. */
export function reevalRadarText(radar: {
	status?: string;
	runNominal?: string | null;
	runAgeSeconds?: number | null;
	maxRunAgeSeconds?: number;
}): string {
	if (!radar.runNominal) return 'Kein veröffentlichter Radarlauf.';
	const age =
		radar.runAgeSeconds === null || radar.runAgeSeconds === undefined
			? ''
			: `, ${formatDuration(radar.runAgeSeconds)} alt`;
	const limit = radar.maxRunAgeSeconds ? ` (Grenze ${formatDuration(radar.maxRunAgeSeconds)})` : '';
	const state = radar.status === 'stale_run' ? ' – zu alt, nichts wird gesendet' : '';
	return `Lauf ${formatDateTime(radar.runNominal)}, Slot 0 (Analyse)${age}${limit}${state}`;
}

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
			const rows =
				(r.subscriptions as
					| (MeasureLike & { index?: number; decision: string; sent?: boolean | null })[]
					| undefined) ?? [];
			const lines = rows.map((s, i) => {
				const head = `Abo ${(s.index ?? i) + 1}: ${decisionName[s.decision] ?? s.decision}${s.sent === true ? ' (gesendet)' : ''}`;
				const why = s.reason && s.reason !== s.decision ? (reasonName[s.reason] ?? s.reason) : '';
				const detail = measureText(s);
				return [head, why, s.measuredClass !== undefined ? detail : ''].filter(Boolean).join(' – ');
			});
			const radar = r.radar
				? reevalRadarText(r.radar as Parameters<typeof reevalRadarText>[0])
				: '';
			return [
				`${r.dryRun ? 'Trockenlauf' : 'Neuauswertung'}: ${lines.join('\n') || 'keine Abos'}.`,
				radar
			]
				.filter(Boolean)
				.join('\n');
		}
		case 'reset_slot':
			return r.cleared === 'none'
				? 'Der Platz war bereits frei.'
				: `Platz freigegeben (${r.cleared === 'reservation' ? 'Reservierung' : 'Live Activity'}).`;
		default:
			return 'Erledigt.';
	}
}

// ---------------------------------------------------------------- Abos eines Geraets

export const subscriptionKind: Record<string, string> = {
	point: 'Punkt (Live Activity oder Ort)',
	circle: 'Umkreis'
};
export const kindLabel = (k: string): string => subscriptionKind[k] ?? k;

/** Automat des Regenbeginns. */
export const subscriptionState: Record<string, { label: string; detail: string }> = {
	dry: {
		label: 'Trocken',
		detail: 'Es wird kein Regen erwartet; der nächste Regenbeginn löst aus.'
	},
	pending: {
		label: 'Regen erwartet',
		detail: 'Regen ist im Vorlauf erkannt, die Benachrichtigung ist vorbereitet.'
	},
	notified: {
		label: 'Benachrichtigt',
		detail: 'Für den aktuellen Regen wurde bereits gesendet; neue Sendung erst nach Trockenphase.'
	}
};
export const subscriptionStateLabel = (s: string): string => subscriptionState[s]?.label ?? s;
export const subscriptionStateDetail = (s: string): string => subscriptionState[s]?.detail ?? '';

export const cellText: Record<string, string> = {
	wet: 'Regen',
	dry: 'trocken',
	unknown: 'unbekannt'
};
export const cellLabel = (c: string): string => cellText[c] ?? c;

export const activityText: Record<string, string> = {
	none: 'Kein Platz belegt',
	reserved: 'Platz reserviert (Start steht aus)',
	active: 'Live Activity läuft'
};
export const activityLabel = (a: string): string => activityText[a] ?? a;

export const radarStatusText: Record<string, string> = {
	ok: 'Radar aktuell',
	no_slot: 'Kein passendes Radarbild vorhanden',
	stale_run: 'Radarlauf veraltet'
};
export const radarStatusLabel = (s: string): string => radarStatusText[s] ?? s;

/** Intensitaetsklassen 1 bis 15 (Radarskala), nur als Zahl benannt: die Zuordnung zu mm/h ist Sache der App. */
export const thresholdText = (c: number): string => classText(c);

// ---------------------------------------------------------------- Cache

export const cacheStateText: Record<
	string,
	{ label: string; tone: 'ok' | 'warn' | 'err' | 'neutral' }
> = {
	current: { label: 'Aktuell', tone: 'ok' },
	stale: { label: 'Veraltet', tone: 'warn' },
	failed: { label: 'Ausgefallen', tone: 'err' },
	empty: { label: 'Leer', tone: 'neutral' },
	disabled: { label: 'Abgeschaltet', tone: 'neutral' }
};
export const cacheKindText: Record<string, string> = {
	radar: 'Radar',
	forecast: 'Vorhersage',
	observation: 'Beobachtung'
};
export const attemptText: Record<string, string> = {
	ok: 'veröffentlicht',
	error: 'fehlgeschlagen',
	missed: 'Slot nicht verfügbar',
	running: 'läuft gerade'
};

export const refreshStatusText: Record<string, string> = {
	queued: 'wartet auf Übernahme',
	running: 'läuft',
	ok: 'abgeschlossen',
	failed: 'fehlgeschlagen',
	expired: 'abgelaufen'
};
export const refreshErrorText: Record<string, string> = {
	source_unavailable: 'Die Quelle (DWD/EUMETSAT) antwortet nicht oder liefert ungültige Bilder.',
	incomplete: 'Die abgerufenen Bilder sind unvollständig.',
	layer_disabled: 'Die Ebene wurde zwischenzeitlich abgeschaltet.',
	no_ingest_replica: 'Kein Replikat hat den Auftrag innerhalb von 2 Minuten übernommen.',
	timeout: 'Der Auftrag lief länger als 5 Minuten ohne Ergebnis.',
	internal: 'Interner Fehler beim Abruf.'
};
export const refreshErrorName = (c: string | null): string =>
	c ? (refreshErrorText[c] ?? c) : 'Unbekannter Fehler.';

/** Ergebniszeile eines abgeschlossenen Auftrags. */
export function refreshResultText(j: {
	result: { stored: number; failed: number; published: boolean } | null;
}): string {
	const r = j.result;
	if (!r) return 'Abgeschlossen.';
	if (r.stored === 0 && r.failed === 0) return 'Es fehlte nichts, nichts Neues geholt.';
	return `${r.stored} ${r.stored === 1 ? 'Bild' : 'Bilder'} gespeichert${r.failed ? `, ${r.failed} fehlgeschlagen` : ''}${r.published ? ', veröffentlicht' : ''}.`;
}

/**
 * Verstaendliche Erklaerung, warum eine Ebene als veraltet oder ausgefallen gilt.
 * `cadenceSeconds` = Erwartung: alle so viele Sekunden ein neuer Lauf.
 */
export function layerReason(l: {
	state: string;
	ageSeconds: number | null;
	cadenceSeconds: number;
	lastAttemptResult: string | null;
	errors24h: number | null;
	newestNominal: string | null;
}): string {
	const expect = `Erwartet wird alle ${formatDuration(l.cadenceSeconds)} ein neuer Lauf.`;
	const age =
		l.ageSeconds === null
			? 'Es wurden noch keine Daten veröffentlicht.'
			: `Seit ${formatDuration(l.ageSeconds)} wurde nichts Neues veröffentlicht.`;
	const attempt =
		l.lastAttemptResult === 'error'
			? ' Der jüngste Abruf ist fehlgeschlagen.'
			: l.lastAttemptResult === 'missed'
				? ' Der jüngste Abruf fand das erwartete Bild nicht (Quelle liefert noch nichts).'
				: l.lastAttemptResult === 'running'
					? ' Ein Abruf läuft gerade.'
					: '';
	const errors = l.errors24h ? ` ${formatNumber(l.errors24h)} Fehlversuche in 24 Stunden.` : '';
	return `${age}${attempt}${errors} ${expect}`;
}

/** Nominalzeit eines Laufs ("20261106T0910Z" oder ISO) als lesbare Zeit; unlesbare Werte bleiben unveraendert. */
export function nominalLabel(id: string): string {
	const m = id.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?Z$/);
	const d = m
		? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)))
		: new Date(id);
	return Number.isNaN(d.getTime()) ? id : formatDateTime(d.toISOString());
}
