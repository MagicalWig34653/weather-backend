import type { Component } from 'svelte';
import CircleCheckIcon from '@lucide/svelte/icons/circle-check';
import TriangleAlertIcon from '@lucide/svelte/icons/triangle-alert';
import CircleXIcon from '@lucide/svelte/icons/circle-x';
import InfoIcon from '@lucide/svelte/icons/info';
import MinusIcon from '@lucide/svelte/icons/minus';

/** Semantische Toene: nie allein Farbe, immer mit Icon und Text. */
export type Tone = 'ok' | 'warn' | 'err' | 'info' | 'neutral';

export const toneIcon: Record<Tone, Component> = {
	ok: CircleCheckIcon,
	warn: TriangleAlertIcon,
	err: CircleXIcon,
	info: InfoIcon,
	neutral: MinusIcon
};

/** Text-/Icon-Farbe (Tinte) je Ton. */
export const toneText: Record<Tone, string> = {
	ok: 'text-ok',
	warn: 'text-warn',
	err: 'text-destructive',
	info: 'text-primary-ink',
	neutral: 'text-muted-foreground'
};

/** Flaeche plus Tinte fuer Badges und Hinweise. */
export const toneSoft: Record<Tone, string> = {
	ok: 'bg-ok-soft text-ok',
	warn: 'bg-warn-soft text-warn',
	err: 'bg-destructive-soft text-destructive',
	info: 'bg-primary-soft text-primary-ink',
	neutral: 'bg-muted text-muted-foreground'
};

/** Fuellung fuer Punkte und Diagramme. */
export const toneFill: Record<Tone, string> = {
	ok: 'bg-ok-fill',
	warn: 'bg-warn-fill',
	err: 'bg-err-fill',
	info: 'bg-primary',
	neutral: 'bg-chart-5'
};

export const toneLabel: Record<Tone, string> = {
	ok: 'In Ordnung',
	warn: 'Warnung',
	err: 'Fehler',
	info: 'Hinweis',
	neutral: 'Neutral'
};
