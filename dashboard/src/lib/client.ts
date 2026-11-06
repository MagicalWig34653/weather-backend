import { ApiClient } from './api';

// Ohne `--mode mock` ist __MOCK__ die Literalkonstante false: Der Mock samt Chunk fehlt im Produktionsbuild.
export const api = new ApiClient({
	fetch: __MOCK__
		? async (input, init) => {
				const { createMockFetch } = await import('./mock');
				mockFetch ??= createMockFetch();
				return mockFetch(input, init);
			}
		: undefined
});

let mockFetch: ((input: string, init?: RequestInit) => Promise<Response>) | undefined;
