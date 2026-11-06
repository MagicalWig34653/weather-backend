/** Der Mock muss dieselbe Form haben wie die Vertrags-Fixtures (Schluesselmengen, rekursiv; null passt zu allem). */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { mockInsights } from './insights/mock';
import { createMockFetch } from './mock';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../docs/fixtures/dashboard');
const present = existsSync(root);
const fx = (n: string): unknown => JSON.parse(readFileSync(resolve(root, n), 'utf8'));

/** Liste der Abweichungen der Schluessel von Mock und Fixture. */
function diff(mock: unknown, fixture: unknown, path = ''): string[] {
	if (mock === null || fixture === null || mock === undefined) return [];
	if (Array.isArray(fixture)) {
		if (!Array.isArray(mock)) return [`${path}: Liste erwartet`];
		const f = fixture[0];
		return f === undefined || mock[0] === undefined ? [] : diff(mock[0], f, `${path}[]`);
	}
	if (typeof fixture === 'object') {
		if (typeof mock !== 'object') return [`${path}: Objekt erwartet`];
		const m = mock as Record<string, unknown>;
		const f = fixture as Record<string, unknown>;
		const out: string[] = [];
		for (const k of Object.keys(f)) {
			if (!(k in m)) out.push(`${path}.${k} fehlt im Mock`);
			else out.push(...diff(m[k], f[k], `${path}.${k}`));
		}
		for (const k of Object.keys(m)) if (!(k in f)) out.push(`${path}.${k} fehlt im Vertrag`);
		return out;
	}
	return typeof mock === typeof fixture
		? []
		: [`${path}: Typ ${typeof mock} statt ${typeof fixture}`];
}

describe.skipIf(!present)('Mock entspricht dem Vertrag', () => {
	const q = (range: string) => new URLSearchParams({ range });
	const cases: [string, unknown, string, string][] = [
		['/insights/overview', fx('insights-overview.200.json'), 'GET', '24h'],
		['/insights/findings', fx('insights-findings.200.json'), 'GET', '24h'],
		['/insights/ops', fx('insights-ops.200.json'), 'GET', '24h'],
		['/insights/traffic', fx('insights-traffic.200.json'), 'GET', '72h'],
		['/insights/push', fx('insights-push.200.json'), 'GET', '24h'],
		['/insights/distribution', fx('insights-distribution.200.json'), 'GET', '24h'],
		['/devices', fx('devices.200.json'), 'GET', '24h'],
		['/devices/x/events', fx('device-events.200.json'), 'GET', '24h']
	];
	for (const [path, fixture, method, range] of cases) {
		it(path, () => {
			let p = path;
			if (path.startsWith('/devices/x')) {
				const id = (
					mockInsights('/devices', 'GET', q(range), {}, 'normal') as { devices: { id: string }[] }
				).devices[0].id;
				p = path.replace('/x/', `/${id}/`);
			}
			const out = mockInsights(p, method, q(range), {}, 'normal');
			expect(diff(out, fixture)).toEqual([]);
		});
	}
	it('Geraetedetail, Diagnose und Befehle', () => {
		const list = mockInsights('/devices', 'GET', q('24h'), {}, 'normal') as {
			devices: { id: string }[];
		};
		const id = list.devices[0].id;
		expect(
			diff(mockInsights(`/devices/${id}`, 'GET', q('24h'), {}, 'normal'), fx('device.200.json'))
		).toEqual([]);
		expect(
			diff(
				mockInsights(`/devices/${id}/diagnosis`, 'GET', q('24h'), {}, 'normal'),
				fx('diagnosis.start_token_missing.json')
			)
		).toEqual([]);
	});
	it('Konfiguration, Protokoll, Neustart und Sitzung', async () => {
		const f = createMockFetch();
		const get = async (p: string) => (await f(`/dash/api${p}`)).json();
		expect(diff(await get('/config'), fx('config.200.json'))).toEqual([]);
		expect(diff(await get('/config/audit?limit=50'), fx('config-audit.200.json'))).toEqual([]);
		expect(diff(await get('/restart'), fx('restart.200.json'))).toEqual([]);
	});
});

describe('diff (Selbstpruefung)', () => {
	it('findet fehlende und ueberzaehlige Schluessel, auch verschachtelt', () => {
		expect(diff({ a: 1 }, { a: 1, b: 2 })).toEqual(['.b fehlt im Mock']);
		expect(diff({ a: 1, c: 1 }, { a: 1 })).toEqual(['.c fehlt im Vertrag']);
		expect(diff({ l: [{ x: 1 }] }, { l: [{ x: 1, y: 1 }] })).toEqual(['.l[].y fehlt im Mock']);
		expect(diff({ a: null }, { a: { b: 1 } })).toEqual([]);
	});
});
