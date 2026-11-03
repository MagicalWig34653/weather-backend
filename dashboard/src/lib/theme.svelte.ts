export type ThemeChoice = 'system' | 'light' | 'dark';
const KEY = 'dash-theme';

class ThemeStore {
	choice = $state<ThemeChoice>('system');

	init(): void {
		const stored = localStorage.getItem(KEY);
		if (stored === 'light' || stored === 'dark') this.choice = stored;
		this.apply();
		matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => this.apply());
	}

	set(choice: ThemeChoice): void {
		this.choice = choice;
		if (choice === 'system') localStorage.removeItem(KEY);
		else localStorage.setItem(KEY, choice);
		this.apply();
	}

	cycle(): void {
		const order: ThemeChoice[] = ['system', 'light', 'dark'];
		this.set(order[(order.indexOf(this.choice) + 1) % order.length]);
	}

	private apply(): void {
		const dark =
			this.choice === 'dark' ||
			(this.choice === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
		document.documentElement.classList.toggle('dark', dark);
	}
}

export const theme = new ThemeStore();
