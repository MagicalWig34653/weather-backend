import { api } from './client';

/** Dateiname `diagnose-<UTC>.json`, z. B. diagnose-20261116T082100Z.json. */
export function diagnoseFilename(now: Date = new Date()): string {
	const p = (n: number) => String(n).padStart(2, '0');
	const d =
		`${now.getUTCFullYear()}${p(now.getUTCMonth() + 1)}${p(now.getUTCDate())}` +
		`T${p(now.getUTCHours())}${p(now.getUTCMinutes())}${p(now.getUTCSeconds())}Z`;
	return `diagnose-${d}.json`;
}

/** Holt den Betriebsexport (nur lesend, ohne Personenbezug) und startet den Dateidownload. Gibt den Dateinamen zurueck. */
export async function downloadDiagnose(): Promise<string> {
	const data = await api.get<unknown>('/diagnose');
	const name = diagnoseFilename();
	const url = URL.createObjectURL(
		new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
	);
	const a = document.createElement('a');
	a.href = url;
	a.download = name;
	document.body.appendChild(a);
	a.click();
	a.remove();
	setTimeout(() => URL.revokeObjectURL(url), 1000);
	return name;
}
