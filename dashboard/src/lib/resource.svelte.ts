import { ApiError } from './api';
import { session } from './session.svelte';
import { ctx } from './design/context.svelte';

/** Laedt Daten einmal und meldet abgelaufene Sitzungen (401) an den Sitzungsspeicher. */
export class Resource<T> {
	data = $state<T | null>(null);
	error = $state<string | null>(null);
	loading = $state(false);
	/** Zeitpunkt (ms) der letzten erfolgreichen Ladung; Grundlage fuer "veraltet". */
	loadedAt = $state<number | null>(null);

	constructor(private readonly loader: () => Promise<T>) {}

	private seq = 0;

	async load(): Promise<void> {
		const mine = ++this.seq;
		this.loading = true;
		try {
			const result = await this.loader();
			if (mine !== this.seq) return; // eine neuere Anfrage ueberholt diese (z. B. Zeitbereich gewechselt)
			this.data = result;
			this.loadedAt = Date.now();
			ctx.updatedAt = this.loadedAt;
			this.error = null;
		} catch (e) {
			if (mine !== this.seq) return;
			if (e instanceof ApiError && e.code === 'unauthorized') {
				session.expire();
				return;
			}
			this.error = e instanceof ApiError ? e.message : 'Unbekannter Fehler.';
		} finally {
			if (mine === this.seq) this.loading = false;
		}
	}
}
