/**
 * pi-coding-agent's own components and themes that extensions use: `tui.ts` shows the components as a divider and a
 * loader, and the themes' terminal styles as colors.
 */

/** A horizontal rule (pi-coding-agent's). */
export class DynamicBorder {
	constructor(_color?: (text: string) => string) {}
	render(width = 40): string[] {
		return ["─".repeat(Math.max(1, width))];
	}
	invalidate(): void {}
}

/** A message with a spinner that Escape cancels (pi-coding-agent's; `signal`, `onAbort`). */
export class BorderedLoader {
	readonly message: string;
	private readonly controller = new AbortController();
	onAbort?: () => void;

	constructor(_tui?: unknown, _theme?: unknown, message = "") {
		this.message = message;
	}

	get signal(): AbortSignal {
		return this.controller.signal;
	}

	render(): string[] {
		return [this.message];
	}

	invalidate(): void {}

	handleInput(data?: string): void {
		if (data !== "\x1b" || this.controller.signal.aborted) return;
		this.controller.abort();
		this.onAbort?.();
	}

	dispose(): void {
		this.controller.abort();
	}
}

/**
 * pi's theme colors as terminal styles, in colors that read in light and dark mode (panels show them; the app's plain
 * text drops them). Backgrounds are left out.
 */
const COLORS: Record<string, string> = {
	accent: "38;2;10;132;255",
	borderAccent: "38;2;10;132;255",
	success: "38;2;48;176;80",
	error: "38;2;255;69;58",
	warning: "38;2;255;159;10",
	muted: "38;2;142;142;147",
	border: "38;2;142;142;147",
	borderMuted: "38;2;142;142;147",
	thinkingText: "38;2;142;142;147",
	mdHeading: "38;2;10;132;255",
	mdLink: "38;2;10;132;255",
	mdLinkUrl: "38;2;142;142;147",
	mdCode: "38;2;10;132;255",
	mdQuote: "38;2;142;142;147",
	mdQuoteBorder: "38;2;142;142;147",
	mdHr: "38;2;142;142;147",
	mdListBullet: "38;2;10;132;255",
	mdCodeBlockBorder: "38;2;142;142;147",
	dim: "2",
};

const styled = (code: string, reset: string) => (text: string) => `\x1b[${code}m${text}\x1b[${reset}m`;

/** pi's `Theme` (`ctx.ui.theme`, and the theme components get): `fg(color, text)`, `bold(text)`, …. */
export const componentTheme = new Proxy(
	{
		fg: (color: string, text: string) => (COLORS[color] ? styled(COLORS[color], color === "dim" ? "22" : "39")(text) : text),
		bg: (_color: string, text: string) => text,
		bold: styled("1", "22"),
		italic: styled("3", "23"),
		underline: styled("4", "24"),
		strikethrough: styled("9", "29"),
		inverse: (text: string) => text,
		getFgAnsi: (color: string) => `\x1b[${COLORS[color] ?? "39"}m`,
		getBgAnsi: () => "\x1b[49m",
		getColorMode: () => "truecolor",
	},
	{ get: (target, key) => (key in target ? Reflect.get(target, key) : key === "then" || typeof key === "symbol" ? undefined : (...args: unknown[]) => args.at(-1)) },
) as { fg(color: string, text: string): string; bold(text: string): string; italic(text: string): string; underline(text: string): string; strikethrough(text: string): string };

const theme = componentTheme;

/** pi's component themes, as its `getSelectListTheme`, `getSettingsListTheme`, and `getMarkdownTheme` make them. */
export const selectListTheme = () => ({
	selectedPrefix: (text: string) => theme.fg("accent", text),
	selectedText: (text: string) => theme.fg("accent", text),
	description: (text: string) => theme.fg("muted", text),
	scrollInfo: (text: string) => theme.fg("muted", text),
	noMatch: (text: string) => theme.fg("muted", text),
});

export const settingsListTheme = () => ({
	label: (text: string, selected: boolean) => (selected ? theme.fg("accent", text) : text),
	value: (text: string, selected: boolean) => (selected ? theme.fg("accent", text) : theme.fg("muted", text)),
	description: (text: string) => theme.fg("dim", text),
	cursor: theme.fg("accent", "→ "),
	hint: (text: string) => theme.fg("dim", text),
});

/** Code blocks are not highlighted. */
export const highlightCode = (code: string) => code.split("\n").map((line) => theme.fg("mdCodeBlock", line));

export const markdownTheme = () => ({
	heading: (text: string) => theme.fg("mdHeading", text),
	link: (text: string) => theme.fg("mdLink", text),
	linkUrl: (text: string) => theme.fg("mdLinkUrl", text),
	code: (text: string) => theme.fg("mdCode", text),
	codeBlock: (text: string) => theme.fg("mdCodeBlock", text),
	codeBlockBorder: (text: string) => theme.fg("mdCodeBlockBorder", text),
	quote: (text: string) => theme.fg("mdQuote", text),
	quoteBorder: (text: string) => theme.fg("mdQuoteBorder", text),
	hr: (text: string) => theme.fg("mdHr", text),
	listBullet: (text: string) => theme.fg("mdListBullet", text),
	bold: (text: string) => theme.bold(text),
	italic: (text: string) => theme.italic(text),
	underline: (text: string) => theme.underline(text),
	strikethrough: (text: string) => theme.strikethrough(text),
	highlightCode,
});
