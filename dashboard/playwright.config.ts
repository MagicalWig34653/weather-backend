import { defineConfig } from '@playwright/test';

// E2E gegen den Mock-Entwicklungsserver (erfundene Daten, kein Backend).
export default defineConfig({
	testDir: './e2e',
	timeout: 60_000,
	retries: 0,
	workers: 1,
	reporter: [['list']],
	webServer: {
		command: 'npm run dev:mock -- --port 5198 --strictPort',
		url: 'http://localhost:5198/dash/',
		reuseExistingServer: false,
		timeout: 60_000
	},
	use: { baseURL: 'http://localhost:5198', headless: true }
});
