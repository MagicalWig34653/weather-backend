import js from '@eslint/js';
import svelte from 'eslint-plugin-svelte';
import globals from 'globals';
import ts from 'typescript-eslint';

export default ts.config(
	{ ignores: ['build/', '.svelte-kit/', 'node_modules/', 'src/lib/components/ui/'] },
	js.configs.recommended,
	...ts.configs.recommended,
	...svelte.configs.recommended,
	{ languageOptions: { globals: { ...globals.browser, ...globals.node, __MOCK__: 'readonly' } } },
	{
		files: ['**/*.svelte', '**/*.svelte.ts'],
		languageOptions: { parserOptions: { parser: ts.parser } }
	},
	{ rules: { 'svelte/no-navigation-without-resolve': 'off' } }
);
