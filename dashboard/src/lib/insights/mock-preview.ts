/** Platzhalterbild fuer die Cache-Vorschau (nur im Mock-Build genutzt; Aufrufe stehen hinter einer Literalkonstante). */
export function mockPreviewUrl(layer: string, slot: string): string {
	const seed = [...slot].reduce((a, c) => (a * 31 + c.charCodeAt(0)) % 997, 7);
	const blobs = Array.from({ length: 6 }, (_, i) => {
		const x = 80 + ((seed * (i + 3) * 37) % 440);
		const y = 80 + ((seed * (i + 5) * 53) % 440);
		const r = 30 + ((seed * (i + 2)) % 60);
		return `<circle cx="${x}" cy="${y}" r="${r}" fill="${['#4cc36b', '#e3d54a', '#e8913a'][i % 3]}" opacity="0.55"/>`;
	}).join('');
	const svg =
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><rect width="600" height="600" fill="#1d3557"/>` +
		`<g fill="none" stroke="#fff" stroke-opacity="0.25"><circle cx="300" cy="300" r="120"/><circle cx="300" cy="300" r="220"/><circle cx="300" cy="300" r="290"/></g>` +
		`${blobs}<text x="16" y="584" fill="#fff" font-family="sans-serif" font-size="18">${layer} ${slot.slice(11, 16)}</text></svg>`;
	return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}
