import { error } from '@sveltejs/kit';
import { MOCK } from '#lib/client.js';

// Vorschauseite des Designsystems: nur im Entwicklungs-/Mock-Build, nicht im Produktionsbuild.
export function load() {
	if (!import.meta.env.DEV && !MOCK) error(404, 'Nicht gefunden');
}
