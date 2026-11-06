import { describe, expect, it } from 'vitest';
import { pollCommand, isFinal } from './poll';
import type { DeviceCommand } from './types';

const cmd = (status: DeviceCommand['status']): DeviceCommand => ({
	commandId: 'c',
	kind: 'test',
	status,
	createdAt: '2026-11-06T09:00:00Z',
	startedAt: null,
	finishedAt: null,
	dryRun: null,
	result: null,
	error: null
});

/** Uhr, die nur durch sleep() voranschreitet. */
function clock() {
	let t = 0;
	return { now: () => t, sleep: async (ms: number) => void (t += ms) };
}

describe('pollCommand', () => {
	it('wartet bis zum Endstatus und meldet Zwischenstaende', async () => {
		const seq = [cmd('queued'), cmd('running'), cmd('done')];
		const seen: string[] = [];
		const out = await pollCommand(async () => seq.shift()!, {
			...clock(),
			onUpdate: (c) => seen.push(c.status)
		});
		expect(out).toMatchObject({ kind: 'final', command: { status: 'done' } });
		expect(seen).toEqual(['queued', 'running', 'done']);
	});
	it.each(['failed', 'expired'] as const)('beendet bei %s', async (s) => {
		const out = await pollCommand(async () => cmd(s), clock());
		expect(out).toMatchObject({ kind: 'final', command: { status: s } });
		expect(isFinal(cmd(s))).toBe(true);
		expect(isFinal(cmd('running'))).toBe(false);
	});
	it('gibt nach der Frist auf (2 Minuten) und nennt den letzten Stand', async () => {
		let calls = 0;
		const out = await pollCommand(async () => (calls++, cmd('running')), clock());
		expect(out).toMatchObject({ kind: 'timeout', last: { status: 'running' } });
		expect(calls).toBe(80); // 120 s / 1,5 s
	});
	it('toleriert einzelne Abfragefehler, gibt aber nach drei in Folge auf', async () => {
		const flaky = [Promise.reject(new Error('x')), Promise.resolve(cmd('done'))];
		const ok = await pollCommand(() => flaky.shift()!, clock());
		expect(ok.kind).toBe('final');
		const boom = new Error('netz');
		let n = 0;
		const out = await pollCommand(async () => (n++, Promise.reject(boom)), clock());
		expect(out).toEqual({ kind: 'error', error: boom });
		expect(n).toBe(3);
	});
	it('bricht bei fatalen Fehlern sofort ab', async () => {
		let n = 0;
		const out = await pollCommand(async () => (n++, Promise.reject(new Error('404'))), {
			...clock(),
			fatal: () => true
		});
		expect(out.kind).toBe('error');
		expect(n).toBe(1);
	});
});
