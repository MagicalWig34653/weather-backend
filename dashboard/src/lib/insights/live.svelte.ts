import { untrack } from 'svelte';
import { Resource } from '#lib/resource.svelte.js';
import { ctx, type Range } from '#lib/design/context.svelte.js';

/**
 * Laedt Daten neu, sobald sich der Zeitbereich aendert oder "Aktualisieren"/Auto-Refresh ausloest.
 * Muss waehrend der Komponenteninitialisierung aufgerufen werden.
 */
export function live<T>(loader: (range: Range) => Promise<T>): Resource<T> {
	const res = new Resource(() => loader(ctx.range));
	$effect(() => {
		void ctx.range;
		void ctx.tick;
		untrack(() => void res.load());
	});
	return res;
}

/** Wie live(), aber ohne Zeitbereich (nur Aktualisieren). */
export function liveStatic<T>(loader: () => Promise<T>): Resource<T> {
	const res = new Resource(loader);
	$effect(() => {
		void ctx.tick;
		untrack(() => void res.load());
	});
	return res;
}
