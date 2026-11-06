import { ApiError } from './api';
import { session } from './session.svelte';
import { ctx } from './design/context.svelte';
import { failureReason, FAILURES_BEFORE_NOTICE, isRetryable, retryDelayMs } from './design/refresh';

/** Stille Wiederholungen je Ladevorgang (zusaetzlich zum ersten Versuch). */
const SILENT_RETRIES = 2;

// Mock-Build: Wartezeiten verkuerzt, damit Zustandstests nicht Sekunden warten (im Produktionsbuild entfernt).
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, __MOCK__ ? ms / 20 : ms));

/**
 * Laedt Daten und meldet abgelaufene Sitzungen (401) an den Sitzungsspeicher.
 * Einzelne Fehlschlaege bleiben unsichtbar: erst stille Wiederholungen mit Backoff (Retry-After bei 429),
 * dann zaehlt der Ladevorgang als fehlgeschlagen; `error` (Hinweis "Veraltet") erscheint erst nach
 * mehreren aufeinanderfolgenden Fehlschlaegen oder wenn noch keine Daten da sind. Nur lokal, keine Telemetrie nach aussen.
 */
export class Resource<T> {
	data = $state<T | null>(null);
	/** Konkreter Grund, nur gesetzt wenn der Hinweis erscheinen soll. */
	error = $state<string | null>(null);
	loading = $state(false);
	/** Zeitpunkt (ms) der letzten erfolgreichen Ladung; Grundlage fuer "veraltet". */
	loadedAt = $state<number | null>(null);
	/** Aufeinanderfolgende fehlgeschlagene Ladevorgaenge (nach stillen Wiederholungen). */
	failures = $state(0);
	lastFailureAt = $state<number | null>(null);

	constructor(private readonly loader: () => Promise<T>) {}

	private seq = 0;

	/** Verwirft laufende Ladevorgaenge und Wiederholungen (Seitenwechsel, Neuladen). */
	cancel(): void {
		this.seq++;
		this.loading = false;
	}

	async load(): Promise<void> {
		const mine = ++this.seq;
		this.loading = true;
		try {
			for (let attempt = 0; ; attempt++) {
				try {
					const result = await this.loader();
					if (mine !== this.seq) return; // eine neuere Anfrage ueberholt diese (z. B. Zeitbereich gewechselt)
					this.data = result;
					this.loadedAt = Date.now();
					ctx.updatedAt = this.loadedAt;
					this.error = null;
					this.failures = 0;
					return;
				} catch (e) {
					if (mine !== this.seq) return;
					if (e instanceof ApiError && e.code === 'unauthorized') {
						session.expire();
						return;
					}
					if (isRetryable(e) && attempt < SILENT_RETRIES) {
						await sleep(retryDelayMs(e, attempt + 1));
						if (mine !== this.seq) return;
						continue;
					}
					this.failures++;
					this.lastFailureAt = Date.now();
					if (this.data === null || this.failures >= FAILURES_BEFORE_NOTICE)
						this.error = failureReason(e);
					return;
				}
			}
		} finally {
			if (mine === this.seq) this.loading = false;
		}
	}
}
