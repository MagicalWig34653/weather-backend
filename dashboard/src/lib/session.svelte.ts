import { api } from './client';
import { ApiError, type SessionState } from './api';

class SessionStore {
	state = $state<SessionState | null>(null);
	loading = $state(true);
	error = $state<string | null>(null);

	async refresh(): Promise<void> {
		try {
			this.state = await api.session();
			this.error = null;
		} catch (e) {
			this.state = null;
			this.error = e instanceof ApiError ? e.message : 'Unbekannter Fehler.';
		} finally {
			this.loading = false;
		}
	}

	async logout(): Promise<void> {
		try {
			await api.logout();
		} finally {
			await this.refresh();
		}
	}

	/** Von Seiten bei 401 aufrufen: die Sitzung ist abgelaufen, es erscheint die Anmeldung. */
	expire(): void {
		void this.refresh();
	}
}

export const session = new SessionStore();
