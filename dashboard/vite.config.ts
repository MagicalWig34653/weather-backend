import adapter from '@sveltejs/adapter-static';
import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
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
});
