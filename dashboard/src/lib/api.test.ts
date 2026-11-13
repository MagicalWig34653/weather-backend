import { describe, expect, it, vi } from 'vitest';
import { ApiClient, ApiError, messageFor, parseRetryAfter, type FetchLike } from './api';

function response(body: unknown, status = 200): Response {
	return new Response(body === undefined ? null : JSON.stringify(body), { status });
}

function setup(res: Response | (() => Promise<Response>)) {
	const fetch = vi.fn<FetchLike>(async () => (typeof res === 'function' ? res() : res));
	return { fetch, api: new ApiClient({ fetch }) };
}

const headersOf = (fetch: ReturnType<typeof setup>['fetch'], i = 0) =>
	fetch.mock.calls[i][1]?.headers as Record<string, string>;

describe('ApiClient: Sitzung', () => {
	it('liest csrfToken (camelCase) und merkt es sich nur im Speicher', async () => {
		const { api, fetch } = setup(
			response({
				state: 'authenticated',
				csrfToken: 'tok',
				credential: { name: 'p', createdAt: '2026-11-03T00:00:00Z' }
			})
		);
		await api.session();
		fetch.mockResolvedValueOnce(response(undefined, 204));
		await api.logout();
		const [url, init] = fetch.mock.calls[1];
		expect(url).toBe('/dash/api/logout');
		expect(headersOf(fetch, 1)['X-CSRF-Token']).toBe('tok');
		expect(init?.credentials).toBe('same-origin');
	});

	it.each([
		[{ state: 'setupOpen', minutesLeft: 12 }],
		[{ state: 'setupClosed' }],
		[{ state: 'login' }]
	])('vergisst das Token bei %o', async (body) => {
		const { api, fetch } = setup(response(body));
		api.setCsrfToken('alt');
		await api.session();
		fetch.mockResolvedValueOnce(response({}));
		await api.setConfig('A', 1);
		expect(headersOf(fetch, 1)['X-CSRF-Token']).toBeUndefined();
	});

	it('sendet challengeId im Body von setup/finish und login/finish', async () => {
		const { api, fetch } = setup(response(undefined, 204));
		const cred = { id: 'i', rawId: 'r', type: 'public-key' as const, response: {} as never };
		await api.setupFinish('cid', cred);
		await api.loginFinish('cid2', cred as never);
		expect(JSON.parse(String(fetch.mock.calls[0][1]?.body))).toMatchObject({ challengeId: 'cid' });
		expect(JSON.parse(String(fetch.mock.calls[1][1]?.body))).toMatchObject({ challengeId: 'cid2' });
		expect(fetch.mock.calls[0][0]).toBe('/dash/api/setup/finish');
	});

	it('tolerieren 204 ohne Koerper', async () => {
		const { api } = setup(response(undefined, 204));
		await expect(api.setupFinish('c', {} as never)).resolves.toBeUndefined();
	});
});

describe('ApiClient: Konfiguration, Protokoll, Neustart', () => {
	it('sendet bei GET weder Content-Type noch CSRF-Token', async () => {
		const { api, fetch } = setup(response({ revision: 1, entries: [] }));
		api.setCsrfToken('tok');
		await api.config();
		expect(headersOf(fetch)['Content-Type']).toBeUndefined();
		expect(headersOf(fetch)['X-CSRF-Token']).toBeUndefined();
	});

	it('sendet typisierte Werte und liefert den Eintrag aus {entry}', async () => {
		const { api, fetch } = setup(response({ entry: { key: 'A', value: 128 } }));
		api.setCsrfToken('tok');
		const e = await api.setConfig('CACHE_MAX_MB', 128);
		expect(e).toEqual({ key: 'A', value: 128 });
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('/dash/api/config/CACHE_MAX_MB');
		expect(init?.method).toBe('PUT');
		expect(init?.body).toBe(JSON.stringify({ value: 128 }));
		expect(headersOf(fetch)['Content-Type']).toBe('application/json');
		expect(headersOf(fetch)['X-CSRF-Token']).toBe('tok');
	});

	it('kodiert Schluessel und setzt zurueck per DELETE', async () => {
		const { api, fetch } = setup(response({ entry: { key: 'A/B' } }));
		await api.resetConfig('A/B');
		expect(fetch.mock.calls[0][0]).toBe('/dash/api/config/A%2FB');
		expect(fetch.mock.calls[0][1]?.method).toBe('DELETE');
	});

	it('fragt das Protokoll mit limit und optionaler Aktion', async () => {
		const { api, fetch } = setup(async () => response({ entries: [] }));
		await api.audit();
		await api.audit(50, 'device_action');
		expect(fetch.mock.calls[0][0]).toBe('/dash/api/config/audit?limit=200');
		expect(fetch.mock.calls[1][0]).toBe('/dash/api/config/audit?limit=50&action=device_action');
	});

	it('loest den Neustart mit leerem Body aus', async () => {
		const { api, fetch } = setup(response({ generation: 5 }, 202));
		await expect(api.requestRestart()).resolves.toEqual({ generation: 5 });
		expect(fetch.mock.calls[0][1]?.body).toBe('{}');
	});
});

describe('ApiClient: Fehler', () => {
	it.each([
		[401, 'unauthorized'],
		[403, 'forbidden'],
		[404, 'not_found'],
		[409, 'conflict'],
		[400, 'validation'],
		[422, 'validation'],
		[429, 'rate_limited'],
		[503, 'unavailable'],
		[500, 'unknown']
	])('bildet Status %i auf %s ab', async (status, code) => {
		const { api } = setup(response({ error: 'x' }, status));
		await expect(api.config()).rejects.toMatchObject({ status, code, serverCode: 'x' });
	});

	it('waehlt den Text nach Servercode, nicht nach Serverfreitext', async () => {
		const { api } = setup(response({ error: 'locked_by_env', message: 'ignoriert' }, 409));
		const err = await api.setConfig('A', 1).catch((e) => e);
		expect(err.serverCode).toBe('locked_by_env');
		expect(err.message).toContain('Umgebungsvariable');
		expect(err.message).not.toContain('ignoriert');
	});

	it('faellt ohne Servercode auf den Statustext zurueck', async () => {
		const { api } = setup(new Response('', { status: 403 }));
		const err = await api.config().catch((e) => e);
		expect(err).toBeInstanceOf(ApiError);
		expect(err.message).toBe('Nicht erlaubt.');
		expect(messageFor(418, null)).toBe("HTTP 418: I'm a Teapot.");
	});

	it('nennt bei 5xx ohne Servercode Status und Grund statt "Unbekannter Fehler"', async () => {
		const { api } = setup(new Response('<html>Bad Gateway</html>', { status: 502 }));
		const err = await api.config().catch((e) => e);
		expect(err).toBeInstanceOf(ApiError);
		expect(err.message).toBe(
			'Der Dienst ist vorübergehend nicht verfügbar (HTTP 502: Bad Gateway).'
		);
		const empty = await setup(new Response('', { status: 500 }))
			.api.config()
			.catch((e) => e);
		expect(empty.message).toBe('HTTP 500: Internal Server Error.');
		expect(empty.message).not.toContain('Unbekannter Fehler');
	});

	it('nimmt den Grund aus dem JSON-Feld reason, wenn kein bekannter Servercode kam', async () => {
		const { api } = setup(response({ error: true, reason: 'Something went wrong.' }, 500));
		const err = await api.config().catch((e) => e);
		expect(err.message).toBe('HTTP 500: Something went wrong.');
		const odd = await setup(response({ error: 'brand_new_code' }, 520))
			.api.config()
			.catch((e) => e);
		expect(odd.message).toBe('HTTP 520: brand_new_code.');
	});

	it('nutzt den Statustext der Antwort, wenn die Tabelle den Status nicht kennt', async () => {
		const { api } = setup(new Response('', { status: 599, statusText: 'Proxy Hiccup' }));
		const err = await api.config().catch((e) => e);
		expect(err.message).toBe('HTTP 599: Proxy Hiccup.');
	});

	it('liest Retry-After bei 429', async () => {
		const { api } = setup(
			new Response(JSON.stringify({ error: 'action_rate_limited' }), {
				status: 429,
				headers: { 'Retry-After': '240' }
			})
		);
		await expect(api.restartState()).rejects.toMatchObject({
			code: 'rate_limited',
			serverCode: 'action_rate_limited',
			retryAfter: 240
		});
	});

	it.each([
		['240', 240],
		['1.2', 2],
		['0', null],
		['-3', null],
		['soon', null],
		['', null],
		[null, null]
	])('parseRetryAfter(%j) = %j', (v, expected) => {
		expect(parseRetryAfter(v)).toBe(expected);
	});

	it('meldet Netzwerkfehler als network und Zeitueberschreitung als timeout', async () => {
		const { api } = setup(() => Promise.reject(new TypeError('offline')));
		await expect(api.config()).rejects.toMatchObject({ code: 'network', status: 0 });
		const t = setup(() => Promise.reject(new DOMException('timeout', 'TimeoutError')));
		await expect(t.api.config()).rejects.toMatchObject({ code: 'timeout', status: 0 });
	});

	it('meldet kaputtes JSON in einer 200-Antwort als Fehler', async () => {
		const { api } = setup(new Response('<html>', { status: 200 }));
		await expect(api.config()).rejects.toMatchObject({ code: 'unknown' });
	});

	it('uebergibt ein Abbruchsignal', async () => {
		const { api, fetch } = setup(response({ entries: [] }));
		await api.config();
		expect(fetch.mock.calls[0][1]?.signal).toBeInstanceOf(AbortSignal);
	});

	it('loescht das Token nach der Abmeldung', async () => {
		const { api, fetch } = setup(response(undefined, 204));
		api.setCsrfToken('tok');
		await api.logout();
		fetch.mockResolvedValueOnce(response({}));
		await api.setConfig('A', 1);
		expect(headersOf(fetch, 1)['X-CSRF-Token']).toBeUndefined();
	});
});
