import { ApiClient } from './api';

/** true nur mit `vite --mode mock`; im Produktionsbuild eine Konstante (toter Code entfaellt). */
export const MOCK = import.meta.env.VITE_MOCK === '1';

export const api = new ApiClient({
	fetch: MOCK
		? async (input, init) => {
				const { createMockFetch } = await import('./mock');
				mockFetch ??= createMockFetch();
				return mockFetch(input, init);
			}
		: undefined
});

let mockFetch: ((input: string, init?: RequestInit) => Promise<Response>) | undefined;
