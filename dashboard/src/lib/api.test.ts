import { describe, expect, it, vi } from 'vitest';
import { ApiClient, ApiError, type FetchLike } from './api';

function response(body: unknown, status = 200): Response {
	return new Response(body === undefined ? null : JSON.stringify(body), { status });
}

function setup(res: Response | (() => Promise<Response>)) {
	const fetch = vi.fn<FetchLike>(async () => (typeof res === 'function' ? res() : res));
	return { fetch, api: new ApiClient({ fetch }) };
}

describe('ApiClient', () => {
	it('liest die Sitzung und merkt sich das CSRF-Token nur im Speicher', async () => {
		const { api, fetch } = setup(
			response({
				state: 'authenticated',
				csrf_token: 'tok',
				credential: { name: 'p', created_at: '2026-11-03T00:00:00Z' }
			})
		);
		await api.session();
		fetch.mockResolvedValueOnce(response(undefined, 204));
		await api.logout();
		const [url, init] = fetch.mock.calls[1];
		expect(url).toBe('/dash/api/logout');
		expect((init?.headers as Record<string, string>)['X-CSRF-Token']).toBe('tok');
		expect(init?.credentials).toBe('same-origin');
	});

	it('sendet bei GET weder Content-Type noch CSRF-Token', async () => {
		const { api, fetch } = setup(response({ entries: [] }));
		api.setCsrfToken('tok');
		await api.config();
		const headers = fetch.mock.calls[0][1]?.headers as Record<string, string>;
		expect(headers['Content-Type']).toBeUndefined();
		expect(headers['X-CSRF-Token']).toBeUndefined();
	});

	it('sendet bei Schreibzugriffen JSON, Content-Type und Token', async () => {
		const { api, fetch } = setup(response({ key: 'A' }));
		api.setCsrfToken('tok');
		await api.setConfig('HISTORY_HOURS', '8');
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('/dash/api/config/HISTORY_HOURS');
		expect(init?.method).toBe('PUT');
		expect(init?.body).toBe(JSON.stringify({ value: '8' }));
		const headers = init?.headers as Record<string, string>;
		expect(headers['Content-Type']).toBe('application/json');
		expect(headers['X-CSRF-Token']).toBe('tok');
	});

	it('kodiert Schluessel und Abfrageparameter', async () => {
		const { api, fetch } = setup(response({ metric: 'bytes', days: [] }));
		await api.daily('bytes', 7);
		expect(fetch.mock.calls[0][0]).toBe('/dash/api/stats/daily?days=7&metric=bytes');
		fetch.mockResolvedValueOnce(response({}));
		await api.resetConfig('A/B');
		expect(fetch.mock.calls[1][0]).toBe('/dash/api/config/A%2FB');
	});

	it('verlangt beim Neustart die ausdrueckliche Bestaetigung', async () => {
		const { api, fetch } = setup(response({ generation: 2, replicas: [], pending_keys: [] }));
		await api.requestRestart();
		expect(fetch.mock.calls[0][1]?.body).toBe(JSON.stringify({ confirm: true }));
	});

	it.each([
		[401, 'unauthorized'],
		[403, 'forbidden'],
		[404, 'not_found'],
		[409, 'conflict'],
		[422, 'validation'],
		[429, 'rate_limited'],
		[500, 'unknown']
	])('bildet Status %i auf %s ab', async (status, code) => {
		const { api } = setup(response({ message: 'Text' }, status));
		await expect(api.config()).rejects.toMatchObject({ status, code, message: 'Text' });
	});

	it('liest Retry-After bei 429', async () => {
		const { api } = setup(
			new Response(JSON.stringify({}), { status: 429, headers: { 'Retry-After': '240' } })
		);
		await expect(api.restartState()).rejects.toMatchObject({
			code: 'rate_limited',
			retryAfter: 240
		});
	});

	it('toleriert Fehlerantworten ohne JSON-Koerper', async () => {
		const { api } = setup(new Response('', { status: 403 }));
		const err = await api.config().catch((e) => e);
		expect(err).toBeInstanceOf(ApiError);
		expect(err.message).toBe('Fehler 403');
	});

	it('meldet Netzwerkfehler als network', async () => {
		const { api } = setup(() => Promise.reject(new TypeError('offline')));
		await expect(api.overview()).rejects.toMatchObject({ code: 'network', status: 0 });
	});

	it('loescht das Token nach der Abmeldung', async () => {
		const { api, fetch } = setup(response(undefined, 204));
		api.setCsrfToken('tok');
		await api.logout();
		fetch.mockResolvedValueOnce(response({}));
		await api.setConfig('A', '1');
		const headers = fetch.mock.calls[1][1]?.headers as Record<string, string>;
		expect(headers['X-CSRF-Token']).toBeUndefined();
	});
});
