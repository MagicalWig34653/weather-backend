/**
 * Vertragstests gegen docs/fixtures (Manifest ordnet Methode, Pfad und Status der Datei zu):
 * Jede Dashboard-Fixture laeuft durch den echten Client und die Datenschicht; Fehlerfixtures muessen
 * auf Code, Text und Wartezeit abgebildet werden, die Oberflaeche muss alle Codes in Klartext kennen.
 * Ohne Fixtures (z. B. im Docker-Kontext) entfaellt die Datei.
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, AUDIT_ACTIONS, type ConfigEntry } from './api';
import { actorOf, details, labelOf, subject } from './audit';
import { api } from './client';
import { draftOf, parseDraft, valuesEqual } from './config/form';
import { errorText } from './errors';
import { describeError, insights } from './insights/api';
import { coordOf } from './insights/grid';
import { checkLabel, formatCode, isValidCode } from './insights/pairing';
import {
	checkName,
	checkText,
	commandErrorName,
	commandResultText,
	eventKindName,
	evalReasonName,
	subscriptionStateView,
	levelLabel,
	measureText,
	activityPreviewText,
	outcomeName,
	reasonName,
	decisionName,
	reevalRadarText,
	summaryText
} from './insights/text';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../docs/fixtures');
const present = existsSync(resolve(root, 'manifest.json'));

interface Fx {
	method: string;
	path: string;
	status: number | null;
	file: string;
	description: string;
}
const manifest: Fx[] = present
	? JSON.parse(readFileSync(resolve(root, 'manifest.json'), 'utf8')).fixtures
	: [];
const read = (file: string): unknown => JSON.parse(readFileSync(resolve(root, file), 'utf8'));
const dash = manifest.filter((f) => f.file.startsWith('dashboard/'));

const ID = 'dev-1';
const CMD = 'cmd-1';
const fill = (p: string) =>
	p
		.replace('{id}', ID)
		.replace('{commandId}', CMD)
		.replace('{key}', 'CACHE_MAX_MB')
		.replace('{action}', 'test')
		.replace('{layer}', 'radar');

/** Aufruf der Datenschicht je Route; fehlt eine Route hier, schlaegt der Test fehl (neue Fixture, keine Abdeckung). */
const calls: Record<string, () => Promise<unknown>> = {
	'GET /dash/api/insights/overview': () => insights.overview('24h'),
	'GET /dash/api/insights/overview?range=24h': () => insights.overview('24h'),
	'GET /dash/api/insights/overview?range=7d': () => insights.overview('7d'),
	'GET /dash/api/insights/overview?range=1y': () => api.get('/insights/overview?range=1y'),
	'GET /dash/api/insights/findings': () => insights.findings(),
	'GET /dash/api/insights/ops?range=24h': () => insights.ops('24h'),
	'GET /dash/api/insights/traffic?range=72h': () => insights.traffic('72h'),
	'GET /dash/api/insights/traffic?range=24h': () => insights.traffic('24h'),
	'GET /dash/api/insights/push?range=24h': () => insights.push('24h'),
	'GET /dash/api/insights/distribution': () => insights.distribution(),
	'PUT /dash/api/push/pause': () => insights.setPaused(true),
	'POST /dash/api/cache/clear': () => insights.clearCache('all'),
	'GET /dash/api/devices': () => insights.devices(),
	'GET /dash/api/devices/{id}/subscriptions': () => insights.deviceSubscriptions(ID),
	'GET /dash/api/cache': () => insights.cache(),
	'GET /dash/api/cache/{layer}/slots': () => api.get('/cache/radar/slots?limit=200'),
	'POST /dash/api/cache/refresh': () => insights.refreshCache('radar'),
	'GET /dash/api/cache/refresh/{id}': () => insights.refreshJob(ID),
	'GET /dash/api/cache/refresh': () => insights.refreshJobs(10),
	'POST /dash/api/devices/pairing': () => insights.openPairing(5),
	'DELETE /dash/api/devices/pairing': () => insights.closePairing(),
	'POST /dash/api/devices/pair': () => insights.pairDevice('7KQ2-M9XD', 'Mein iPhone'),
	'GET /dash/api/devices/{id}': () => api.get(`/devices/${ID}`),
	'GET /dash/api/devices/{id}/diagnosis': () => api.get(`/devices/${ID}/diagnosis`),
	'GET /dash/api/devices/{id}/events?limit=50': () => api.get(`/devices/${ID}/events?limit=50`),
	'POST /dash/api/devices/{id}/actions/{action}': () => insights.runAction(ID, 'test'),
	'GET /dash/api/devices/{id}/commands/{commandId}': () => insights.command(ID, CMD),
	'GET /dash/api/devices/{id}/commands?limit=10': () => insights.commands(ID, 10),
	'DELETE /dash/api/devices/{id}': () => insights.unpairDevice(ID),
	'GET /dash/api/config': () => api.config(),
	'PUT /dash/api/config/{key}': async () => ({ entry: await api.setConfig('CACHE_MAX_MB', 128) }),
	'GET /dash/api/config/audit?limit=50': () => api.audit(50),
	'GET /dash/api/restart': () => api.restartState(),
	'POST /dash/api/restart': () => api.requestRestart()
};

let last: { url: string; init?: RequestInit } | null = null;
function serve(fx: Fx): void {
	const body = fx.status === 204 ? null : JSON.stringify(read(fx.file));
	vi.stubGlobal(
		'fetch',
		vi.fn(async (url: string, init?: RequestInit) => {
			last = { url, init };
			return new Response(body, {
				status: fx.status ?? 200,
				headers: fx.status === 429 ? { 'Retry-After': '42' } : {}
			});
		})
	);
}
afterEach(() => vi.unstubAllGlobals());

describe.skipIf(!present)('Fixture-Satz', () => {
	it('jede Datei des Manifests existiert und ist gueltiges JSON, keine Datei fehlt im Manifest', () => {
		for (const f of manifest) expect(() => read(f.file), f.file).not.toThrow();
		const listed = new Set(manifest.map((f) => f.file));
		for (const dir of ['app', 'dashboard'])
			for (const name of readdirSync(resolve(root, dir)))
				expect(listed.has(`${dir}/${name}`), `${dir}/${name} fehlt im Manifest`).toBe(true);
	});
});

describe.skipIf(!present)('Datenschicht liefert jede Erfolgs-Fixture unveraendert', () => {
	const ok = dash.filter((f) => f.status !== null && f.status < 400 && !f.path.endsWith('/*'));
	for (const f of ok) {
		it(`${f.method} ${f.path} -> ${f.status} (${f.file})`, async () => {
			const key = `${f.method} ${f.path}`;
			const call = calls[key];
			expect(call, `keine Abdeckung fuer ${key}`).toBeTypeOf('function');
			serve(f);
			const out = await call();
			expect(out).toEqual(f.status === 204 ? undefined : read(f.file));
			// Pfad und Methode wie im Manifest
			// Manifest-Pfade ohne Query vergleichen nur den Pfad (Parameter wie limit/range sind Zusatz).
			expect(f.path.includes('?') ? last?.url : last?.url.split('?')[0]).toBe(fill(f.path));
			expect(last?.init?.method ?? 'GET').toBe(f.method);
		});
	}
});

describe.skipIf(!present)('Request-Bodies entsprechen den Request-Fixtures', () => {
	const reqs = dash.filter((f) => f.status === null);
	for (const f of reqs) {
		it(f.file, async () => {
			const ok = dash.find(
				(x) => x.method === f.method && x.path === f.path && x.status !== null && x.status < 400
			)!;
			serve(ok);
			await calls[`${f.method} ${f.path}`]();
			const expected = read(f.file);
			if (f.file === 'dashboard/action.reeval.request.json') {
				// reeval nimmt dryRun; die uebrigen Aktionen senden {}
				serve(ok);
				await insights.runAction(ID, 'reeval', true);
				expect(JSON.parse(String(last?.init?.body))).toEqual(expected);
				await insights.runAction(ID, 'test');
				expect(JSON.parse(String(last?.init?.body))).toEqual({});
			} else {
				expect(JSON.parse(String(last?.init?.body))).toEqual(expected);
			}
		});
	}
});

describe.skipIf(!present)('Fehler-Fixtures: Code, Text, Wartezeit', () => {
	const errs = dash.filter((f) => f.status !== null && f.status >= 400);
	for (const f of errs) {
		it(`${f.status} ${f.file}`, async () => {
			const fx = read(f.file) as { error: string };
			serve(f);
			const path = f.path.endsWith('/*')
				? '/insights/overview'
				: fill(f.path).replace('/dash/api', '');
			const err = (await api.get(path).catch((e) => e)) as ApiError;
			expect(err).toBeInstanceOf(ApiError);
			expect(err.status).toBe(f.status);
			expect(err.serverCode).toBe(fx.error);
			// Klartext fuer jeden Servercode, nie der Rohcode
			expect(errorText[fx.error], `Text fuer ${fx.error}`).toBeTypeOf('string');
			expect(describeError(err)).toContain(errorText[fx.error]);
			if (f.status === 429) {
				expect(err.retryAfter).toBe(42);
				expect(describeError(err)).toMatch(/Erneut möglich in 42 s/);
			}
		});
	}
	it('kennt alle Codes der Fehlerzusammenfassung des Vertrags', () => {
		for (const c of [
			'validation',
			'unauthorized',
			'forbidden',
			'not_found',
			'code_unknown',
			'conflict',
			'device_limit',
			'link_disabled',
			'command_pending',
			'locked_by_env',
			'rate_limited',
			'action_rate_limited',
			'data_unavailable'
		])
			expect(errorText[c], c).toBeTypeOf('string');
	});
});

describe.skipIf(!present)('Darstellung deckt die Fixtures ab (keine Rohcodes)', () => {
	const files = (prefix: string) =>
		dash.filter((f) => f.file.startsWith(`dashboard/${prefix}`)).map((f) => f.file);

	it('Geraete: Zusammenfassung und Stufe haben Klartext', () => {
		for (const file of files('devices.')) {
			const d = read(file) as {
				devices?: { summary: { code: string; level: string }; env: string }[];
			};
			for (const x of d.devices ?? []) {
				expect(summaryText[x.summary.code], x.summary.code).toBeTypeOf('string');
				expect(levelLabel[x.summary.level as 'ok'], x.summary.level).toBeTypeOf('string');
			}
		}
	});
	it('Diagnose: jede Pruefung hat Name und Text', () => {
		for (const file of files('diagnosis.')) {
			const d = read(file) as {
				checks: { code: string; reason: string }[];
				verdict: { code: string } | null;
			};
			expect(d.checks).toHaveLength(9);
			for (const c of d.checks) {
				expect(checkName[c.code], c.code).toBeTypeOf('string');
				expect(checkText(c.code, c.reason), `${c.code}/${c.reason}`).not.toBe(
					`${c.code}: ${c.reason}`
				);
			}
			if (d.verdict) expect(checkName[d.verdict.code]).toBeTypeOf('string');
		}
	});
	it('Ereignisse: Art und Ergebnis haben Klartext', () => {
		for (const file of files('device-events.')) {
			for (const e of (read(file) as { events: { kind: string; outcome: string }[] }).events) {
				expect(eventKindName[e.kind], e.kind).toBeTypeOf('string');
				expect(outcomeName[e.outcome], e.outcome).toBeTypeOf('string');
			}
		}
	});
	it('Auftraege: Ergebnis-, Fehler- und Statustexte', () => {
		for (const file of files('command.')) {
			const c = read(file) as {
				kind: string;
				status: string;
				result: Record<string, unknown> | null;
				error: string | null;
			};
			if (c.status === 'done') {
				const text = commandResultText(c.kind, c.result);
				expect(text).not.toBe('Erledigt.');
				expect(text).not.toMatch(/undefined|\[object/);
			}
			if (c.status === 'failed') expect(commandErrorName[c.error!], c.error!).toBeTypeOf('string');
		}
		const list = read('dashboard/commands.200.json') as {
			commands: { kind: string; result: Record<string, unknown> }[];
		};
		for (const c of list.commands)
			expect(commandResultText(c.kind, c.result)).toMatch(/Abo 1: würde auslösen/);
	});
	it('Abos und Neuauswertung: Ort stimmt mit dem Raster ueberein, Grund und Messung haben Klartext', () => {
		const places: { lat: number; lon: number; x: number; y: number }[] = [];
		for (const file of files('device-subscriptions.')) {
			const d = read(file) as { subscriptions: { place?: (typeof places)[number] | null }[] };
			for (const s of d.subscriptions) if (s.place) places.push(s.place);
		}
		const reeval = read('dashboard/command.done-reeval.json') as {
			result: {
				radar: Parameters<typeof reevalRadarText>[0];
				subscriptions: { decision: string; reason: string; place?: (typeof places)[number] }[];
			};
		};
		for (const s of reeval.result.subscriptions) {
			expect(decisionName[s.decision], s.decision).toBeTypeOf('string');
			expect(reasonName[s.reason], s.reason).toBeTypeOf('string');
			if (s.place) places.push(s.place);
		}
		expect(places.length).toBeGreaterThan(2);
		for (const p of places) {
			const c = coordOf(p.x, p.y);
			expect(Math.abs(c.lat - p.lat)).toBeLessThan(0.006);
			expect(Math.abs(c.lon - p.lon)).toBeLessThan(0.006);
		}
		const text = commandResultText('reeval', reeval.result as unknown as Record<string, unknown>);
		expect(text).toContain('Abo 1: unter der Schwelle – Regen im Radar, aber unter der Schwelle');
		expect(text).toContain('jetzt: Klasse 2 (ab 0,2 mm/h) · Schwelle: Klasse 3 (ab 0,4 mm/h)');
		expect(text).toContain('Anteil 0 % (0 von 4301 Zellen, nötig 44) gegen 1 %');
		expect(text).toContain('Slot 0 (Analyse), 2 min alt');
		expect(measureText({ reason: 'pixel_unknown', measuredClass: null })).toBe('Pixel unbekannt');
	});
	it('Abos: Grund der echten Auswertung hat Klartext, Zustand widerspricht nicht der laufenden Live Activity', () => {
		for (const file of files('device-subscriptions.')) {
			const d = read(file) as {
				subscriptions: {
					state: string;
					cell: string;
					activity: string;
					hysteresis: boolean;
					liveActivity: boolean;
					lastEval?: { reason: string } | null;
				}[];
			};
			for (const s of d.subscriptions) {
				if (s.lastEval)
					expect(evalReasonName[s.lastEval.reason], s.lastEval.reason).toBeTypeOf('string');
				if (s.activity === 'active')
					expect(subscriptionStateView(s).label).toBe('Live Activity läuft');
			}
		}
		const view = (cell: string, hysteresis: boolean) =>
			subscriptionStateView({
				state: 'dry',
				cell,
				activity: 'none',
				hysteresis,
				liveActivity: true
			}).label;
		expect(view('dry', false)).toBe('Trocken');
		expect(view('wet', false)).toBe('Regen erkannt');
		expect(view('wet', true)).toBe('Regen läuft, noch nicht gestartet');
	});
	it('Gebiets-Live-Activity: Vorschau, unbekannte Zellen und neue Gruende haben Klartext', () => {
		const d = read('dashboard/device-subscriptions.200.json') as {
			subscriptions: {
				kind: string;
				liveActivity: boolean;
				activityPreview?: Parameters<typeof activityPreviewText>[0];
			}[];
		};
		const region = d.subscriptions.find((s) => s.kind === 'circle' && s.liveActivity);
		expect(region?.activityPreview).toBeTruthy();
		expect(activityPreviewText(region?.activityPreview)).toBe(
			'Umkreis 4 km: 0 % der Fläche nass (Spitze 12 % in 60 min), bis Klasse 3 (ab 0,4 mm/h)'
		);
		expect(activityPreviewText(null)).toBe('');
		expect(reasonName['share_unknown']).toBeTypeOf('string');
		expect(reasonName['would_displace_region']).toBeTypeOf('string');
		expect(
			measureText({
				kind: 'circle',
				measuredClass: 3,
				wetCells: 6,
				cells: 81,
				neededCells: 9,
				sharePercent: 7.4,
				minSharePercent: 10,
				unknownCells: 3,
				unknownSharePercent: 3.7
			})
		).toContain('3 Zellen unbekannt (3,7 %)');
		// Punkt-Abos tragen keine Vorschau.
		for (const s of d.subscriptions.filter((x) => x.kind === 'point'))
			expect(s.activityPreview ?? null).toBeNull();
	});
	it('Reeval zeigt "gesendet" und nummeriert nach index', () => {
		expect(
			commandResultText('reeval', {
				dryRun: false,
				subscriptions: [{ index: 2, decision: 'would_trigger', sent: true }]
			})
		).toBe('Neuauswertung: Abo 3: würde auslösen (gesendet).');
	});
	it('Protokoll: Aktionen bekannt, Texte vorhanden, Geraetebezug 8 Hexzeichen', () => {
		for (const file of files('config-audit.')) {
			for (const e of (read(file) as { entries: Parameters<typeof subject>[0][] }).entries) {
				expect(AUDIT_ACTIONS).toContain(e.action);
				expect(labelOf(e.action)).not.toBe(e.action);
				expect(subject(e)).not.toBe('');
				expect(details(e).length).toBeGreaterThanOrEqual(4);
				expect(actorOf(e)).toBe('operator');
				if (e.deviceRef) expect(e.deviceRef).toMatch(/^[0-9a-f]{8}$/);
			}
		}
	});
	it('Kopplungs-Request ist gueltig und unveraendert formatiert', () => {
		const r = read('dashboard/devices-pair.request.json') as { code: string; label: string };
		expect(isValidCode(r.code)).toBe(true);
		expect(formatCode(r.code)).toBe(r.code);
		expect(checkLabel(r.label)).toMatchObject({ ok: true });
		const bad = read('dashboard/devices-pair.400-validation.json');
		expect(bad).toEqual({ error: 'validation' });
	});
});

describe.skipIf(!present)('Konfiguration: Register-Fixture in der Formularlogik', () => {
	const cfg = (present ? read('dashboard/config.200.json') : { entries: [] }) as {
		revision: number;
		entries: ConfigEntry[];
	};
	it('hat den Vertragskopf und alle Pflichtfelder', () => {
		expect(cfg.revision).toBeTypeOf('number');
		for (const e of cfg.entries)
			for (const k of [
				'key',
				'group',
				'type',
				'default',
				'min',
				'max',
				'unit',
				'description',
				'apply',
				'source',
				'locked',
				'value',
				'restartPending'
			])
				expect(e, `${e.key}.${k}`).toHaveProperty(k);
	});
	it('Wert -> Entwurf -> Wert ist stabil und gueltig (nicht gesperrte Eintraege)', () => {
		for (const e of cfg.entries.filter((x) => !x.locked)) {
			const p = parseDraft(e, draftOf(e));
			expect(p.ok, e.key).toBe(true);
			if (p.ok) expect(valuesEqual(p.value, e.value), e.key).toBe(true);
		}
	});
	it('gesperrte Eintraege ohne Wert (Geheimnis) bleiben unlesbar', () => {
		const secret = cfg.entries.find((e) => e.value === null)!;
		expect(secret.locked).toBe(true);
	});
	it('Request-Fixture der Aenderung ist fuer den Eintrag gueltig', () => {
		const req = read('dashboard/config-put.request.json') as { value: number };
		const entry = cfg.entries.find((e) => e.key === 'CACHE_MAX_MB')!;
		expect(parseDraft(entry, String(req.value))).toEqual({ ok: true, value: req.value });
		expect(parseDraft(entry, '4').ok).toBe(false);
	});
});
