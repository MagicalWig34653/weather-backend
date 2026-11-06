/** Wie alt Daten sein duerfen, bevor "veraltet" erscheint: das Doppelte des Abrufintervalls. */
export function isStale(loadedAt: number | null, now: number, intervalMs: number): boolean {
	return loadedAt !== null && now - loadedAt > intervalMs * 2;
}
