import type { Component } from 'svelte';
import LayoutDashboardIcon from '@lucide/svelte/icons/layout-dashboard';
import ActivityIcon from '@lucide/svelte/icons/activity';
import GaugeIcon from '@lucide/svelte/icons/gauge';
import BellRingIcon from '@lucide/svelte/icons/bell-ring';
import PieChartIcon from '@lucide/svelte/icons/chart-pie';
import SmartphoneIcon from '@lucide/svelte/icons/smartphone';
import SlidersIcon from '@lucide/svelte/icons/sliders-horizontal';
import ScrollTextIcon from '@lucide/svelte/icons/scroll-text';

export interface NavItem {
	href: string;
	label: string;
	title: string;
	icon: Component;
	/** Seite nutzt den globalen Zeitbereich. */
	range: boolean;
	/** Erscheint in der unteren Tab-Leiste (Telefon). */
	tab?: boolean;
}

export interface NavGroup {
	label: string;
	items: NavItem[];
}

export const NAV: NavGroup[] = [
	{
		label: 'Überblick',
		items: [
			{
				href: '/',
				label: 'Übersicht',
				title: 'Übersicht',
				icon: LayoutDashboardIcon,
				range: true,
				tab: true
			},
			{
				href: '/betrieb',
				label: 'Betrieb',
				title: 'Betrieb',
				icon: ActivityIcon,
				range: true,
				tab: true
			},
			{ href: '/traffic', label: 'Traffic', title: 'Traffic', icon: GaugeIcon, range: true }
		]
	},
	{
		label: 'Push',
		items: [
			{
				href: '/push',
				label: 'Push',
				title: 'Push und Live Activities',
				icon: BellRingIcon,
				range: true,
				tab: true
			},
			{
				href: '/abos',
				label: 'Abos',
				title: 'Abos und Verteilung',
				icon: PieChartIcon,
				range: false
			},
			{
				href: '/geraete',
				label: 'Geräte',
				title: 'Geräte',
				icon: SmartphoneIcon,
				range: false,
				tab: true
			}
		]
	},
	{
		label: 'System',
		items: [
			{
				href: '/konfiguration',
				label: 'Konfiguration',
				title: 'Konfiguration',
				icon: SlidersIcon,
				range: false
			},
			{
				href: '/protokoll',
				label: 'Protokoll',
				title: 'Änderungsprotokoll',
				icon: ScrollTextIcon,
				range: false
			}
		]
	}
];

export const ALL_ITEMS: NavItem[] = NAV.flatMap((g) => g.items);

/** Aktiver Eintrag fuer einen Pfad ohne Basispfad ("/", "/betrieb" ...). */
export function activeItem(path: string): NavItem | undefined {
	const p = path.replace(/\/$/, '') || '/';
	return ALL_ITEMS.find((i) =>
		i.href === '/' ? p === '/' : p === i.href || p.startsWith(i.href + '/')
	);
}
