import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { bucketLabels, unpack } from './series';
import { checkText, findingHref, findingText } from './text';

// Die Fixtures liegen im Backend-Repo (docs/fixtures/dashboard); ohne sie (z. B. im Docker-Kontext) entfaellt der Test.
const dir = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../docs/fixtures/dashboard');
const present = existsSync(dir);

function* seriesIn(
	x: unknown
): Generator<{ resolution: 'hour' | 'day'; points: { t: string; v: number | null }[] }> {
	if (Array.isArray(x)) for (const y of x) yield* seriesIn(y);
	else if (x && typeof x === 'object') {
		const o = x as Record<string, unknown>;
		if (Array.isArray(o.points) && typeof o.resolution === 'string') yield o as never;
		else for (const y of Object.values(o)) yield* seriesIn(y);
	}
}

describe.skipIf(!present)('Vertrags-Fixtures', () => {
	const files = present
		? readdirSync(dir).filter((f) => f.startsWith('insights-') && f.endsWith('.json'))
		: [];
	it('Fixtures vorhanden', () => expect(files.length).toBeGreaterThan(5));
	for (const f of files) {
		it(`${f}: Reihen sind aufsteigend und beschriftbar`, () => {
			const json = JSON.parse(readFileSync(resolve(dir, f), 'utf8'));
			for (const s of seriesIn(json)) {
				const { t } = unpack(s);
				expect([...t].sort()).toEqual(t);
				const l = bucketLabels(t, s.resolution);
				expect(l.categories).toHaveLength(t.length);
			}
		});
	}
	it('Befunde und Diagnose haben deutsche Texte', () => {
		const fi = JSON.parse(readFileSync(resolve(dir, 'insights-findings.critical.json'), 'utf8'));
		for (const f of fi.findings) {
			const t = findingText(f);
			expect(t.title).not.toBe(f.code);
			expect(findingHref(f)).toMatch(/^\//);
		}
		const dg = JSON.parse(readFileSync(resolve(dir, 'diagnosis.start_token_missing.json'), 'utf8'));
		for (const c of dg.checks) expect(checkText(c.code, c.reason)).not.toContain(`${c.code}: `);
	});
});
