import type { Tone } from './tone';

export interface ToastItem {
	id: number;
	tone: Tone;
	title: string;
	detail?: string;
}

class ToastStore {
	items = $state<ToastItem[]>([]);
	private next = 1;

	push(tone: Tone, title: string, detail?: string, ms = 5000): void {
		const id = this.next++;
		this.items = [...this.items, { id, tone, title, detail }].slice(-4);
		if (ms > 0) setTimeout(() => this.dismiss(id), ms);
	}
	success(title: string, detail?: string): void {
		this.push('ok', title, detail);
	}
	error(title: string, detail?: string): void {
		this.push('err', title, detail, 8000);
	}
	dismiss(id: number): void {
		this.items = this.items.filter((t) => t.id !== id);
	}
}

export const toast = new ToastStore();
