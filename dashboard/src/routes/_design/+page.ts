import { error } from '@sveltejs/kit';

// Vorschauseite des Designsystems: nur im Entwicklungs-/Mock-Build, nicht im Produktionsbuild.
export function load() {
	if (!import.meta.env.DEV && !__MOCK__) error(404, 'Nicht gefunden');
}
