import adapter from '@sveltejs/adapter-static';
import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

/** Leitet /dash/api an ein echtes Backend weiter; Host und Origin werden auf das Ziel gesetzt (Pruefungen des Servers). */
function devProxy(target: string) {
	const origin = new URL(target).origin;
	return {
		'/dash/api': {
			target,
			changeOrigin: true,
			headers: { Origin: origin }
		}
	};
}

// `npm run dev:mock` (mode "mock") ist der einzige Weg, den Mock-Server und die Design-Vorschau zu laden.
// __MOCK__ ist an jeder Verwendung eine Literalkonstante: Im Produktionsbuild entfaellt der Code samt Chunks.
// Entwicklung gegen ein echtes Backend: DASH_API_TARGET=http://host:port npm run dev (siehe README).
export default defineConfig(({ mode }) => ({
	define: { __MOCK__: JSON.stringify(mode === 'mock') },
	server: process.env.DASH_API_TARGET
		? { proxy: devProxy(process.env.DASH_API_TARGET) }
		: undefined,
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Runes-Modus fuer das ganze Projekt, ausser fuer Abhaengigkeiten.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// Statischer SPA-Build, vom Backend unter /dash ausgeliefert (Plan 6.1).
			adapter: adapter({ fallback: 'index.html', strict: false }),
			paths: { base: '/dash', relative: false }
		})
	],
	test: {
		environment: 'jsdom',
		include: ['src/**/*.test.ts']
	}
}));
