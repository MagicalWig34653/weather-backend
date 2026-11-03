import { ApiError } from './api';
import { session } from './session.svelte';

/** Laedt Daten einmal und meldet abgelaufene Sitzungen (401) an den Sitzungsspeicher. */
export class Resource<T> {
	data = $state<T | null>(null);
	error = $state<string | null>(null);
	loading = $state(false);

	constructor(private readonly loader: () => Promise<T>) {}

	async load(): Promise<void> {
		this.loading = true;
		try {
			this.data = await this.loader();
			this.error = null;
		} catch (e) {
			if (e instanceof ApiError && e.code === 'unauthorized') {
				session.expire();
				return;
			}
			this.error = e instanceof ApiError ? e.message : 'Unbekannter Fehler.';
		} finally {
			this.loading = false;
		}
	}
}
