import type { DeviceCommand } from './types';

export type PollOutcome =
	| { kind: 'final'; command: DeviceCommand }
	/** Kein Endstatus innerhalb der Frist. */
	| { kind: 'timeout'; last: DeviceCommand | null }
	/** Wiederholt keine Antwort (Netz, Sitzung, geloeschtes Geraet). */
	| { kind: 'error'; error: unknown };

export interface PollOptions {
	/** Abstand der Abfragen (Vertrag: 1 bis 2 s). */
	intervalMs?: number;
	/** Hoechstdauer (Vertrag: 2 Minuten). */
	timeoutMs?: number;
	/** Aufeinanderfolgende Abfragefehler, nach denen aufgegeben wird. */
	maxErrors?: number;
	sleep?: (ms: number) => Promise<void>;
	now?: () => number;
	onUpdate?: (c: DeviceCommand) => void;
	/** Fehler, die sofort abbrechen (z. B. 401/404). */
	fatal?: (e: unknown) => boolean;
}

const finals = new Set(['done', 'failed', 'expired']);
export const isFinal = (c: DeviceCommand): boolean => finals.has(c.status);

/** Fragt einen Auftrag ab, bis er einen Endstatus hat, die Frist ablaeuft oder die Abfrage wiederholt scheitert. */
export async function pollCommand(
	fetchOnce: () => Promise<DeviceCommand>,
	o: PollOptions = {}
): Promise<PollOutcome> {
	const interval = o.intervalMs ?? 1500;
	const timeout = o.timeoutMs ?? 120_000;
	const maxErrors = o.maxErrors ?? 3;
	const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
	const now = o.now ?? Date.now;
	const start = now();
	let last: DeviceCommand | null = null;
	let errors = 0;
	while (now() - start < timeout) {
		await sleep(interval);
		try {
			last = await fetchOnce();
			errors = 0;
			o.onUpdate?.(last);
			if (isFinal(last)) return { kind: 'final', command: last };
		} catch (e) {
			if (o.fatal?.(e) || ++errors >= maxErrors) return { kind: 'error', error: e };
		}
	}
	return { kind: 'timeout', last };
}
