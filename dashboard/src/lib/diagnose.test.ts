import { describe, expect, it } from 'vitest';
import { diagnoseFilename } from './diagnose';

describe('diagnoseFilename', () => {
	it('nutzt UTC im Format diagnose-<UTC>.json', () => {
		expect(diagnoseFilename(new Date('2026-11-16T09:21:05+01:00'))).toBe(
			'diagnose-20261116T082105Z.json'
		);
	});
});
