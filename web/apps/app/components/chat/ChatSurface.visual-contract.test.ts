import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function readAppFile(relativePath: string): string {
  return readFileSync(join(process.cwd(), relativePath), 'utf8');
}

function cssClassBlock(source: string, className: string): string {
  const marker = `.${className} {`;
  const start = source.indexOf(marker);
  expect(start).toBeGreaterThanOrEqual(0);
  const bodyStart = start + marker.length;
  const end = source.indexOf('\n}', bodyStart);
  expect(end).toBeGreaterThan(bodyStart);
  return source.slice(bodyStart, end);
}

describe('Chat surface visual contracts', () => {
  it('keeps chat ambient aurora theme values tokenized', () => {
    const css = readAppFile('components/chat/ChatAmbientAurora.module.css');

    expect(css).toContain('var(--o-chat-aurora-glow-bg)');
    expect(css).toContain('var(--o-chat-aurora-halftone-dot)');
    expect(css).not.toContain(":global(html[data-theme='dark']) .glow");
    expect(css).not.toContain(":global(html[data-theme='dark']) .halftone");
  });

  it('renders the top bar as a light glass scrim over the ambient chat surface', () => {
    const css = readAppFile('components/chat/TopBar.module.css');
    const bar = cssClassBlock(css, 'bar');

    expect(bar).toContain('var(--o-chat-topbar-bg)');
    expect(bar).toContain('backdrop-filter');
    expect(css).toContain('var(--o-chat-topbar-border)');
  });

  it('keeps composer glass styling tokenized instead of using module dark overrides', () => {
    const css = readAppFile('components/chat/InputComposer.module.css');

    expect(css).toContain('var(--o-composer-bg)');
    expect(css).toContain('var(--o-composer-home-bg)');
    expect(css).toContain('var(--o-composer-hover-shadow)');
    expect(css).toContain('var(--o-composer-focus-shadow)');
    expect(css).not.toContain(":global(html[data-theme='dark']) .composer");
    expect(css).not.toContain(":global(html[data-theme='dark']) .wrapHome .composer");
  });

  it('keeps sent message text readable on the branded user bubble', () => {
    const css = readAppFile('components/chat/MessageBubble.module.css');
    const userBubble = cssClassBlock(css, "row[data-role='user'] .bubble");

    // Light and dark values live in the --o-user-bubble-* tokens: purple with white text in light mode, the current palette gradient + onPrimary in dark mode
    expect(userBubble).toContain('background: var(--o-user-bubble-bg);');
    expect(userBubble).toContain('color: var(--o-user-bubble-fg);');
    expect(userBubble).toContain('box-shadow: var(--o-user-bubble-shadow);');
    expect(userBubble).not.toContain('color: var(--o-primary-text)');
  });

  it('keeps MessageBubble free of literal colors so dark palettes can follow', () => {
    // Strip comments before checking: explanatory text inside comments does not count
    const css = readAppFile('components/chat/MessageBubble.module.css').replace(/\/\*[\s\S]*?\*\//g, '');
    const literals = css.match(/#[0-9a-fA-F]{3,8}\b|\brgba?\(/g) ?? [];
    expect(literals).toEqual([]);
  });

  it('styles markdown inline code through the inline-code tokens so dark palettes can follow', () => {
    const css = readAppFile('components/chat/MarkdownRenderer.module.css');
    const inline = cssClassBlock(css, 'inlineCode');

    expect(inline).toContain('background: var(--o-code-inline-bg);');
    expect(inline).toContain('color: var(--o-code-inline-text);');
  });

  it('renders sidebar conversation provider logos without an extra frame', () => {
    const css = readAppFile('components/sidebar/ConversationItem.module.css');
    const source = readAppFile('components/sidebar/ConversationItem.tsx');
    const avatar = cssClassBlock(css, 'avatar');

    expect(avatar).toContain('background: transparent;');
    expect(avatar).not.toContain('box-shadow:');
    expect(source).toContain('bare');
  });
});
