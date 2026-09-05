import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function readChatViewStyles(): string {
  return readFileSync(join(process.cwd(), 'components/chat/ChatView.module.css'), 'utf8');
}

function readInputComposerStyles(): string {
  return readFileSync(join(process.cwd(), 'components/chat/InputComposer.module.css'), 'utf8');
}

function extractClassZIndex(css: string, className: string): number {
  const match = css.match(new RegExp(`\\.${className}\\s*\\{[\\s\\S]*?z-index:\\s*(\\d+);`));
  if (!match) throw new Error(`Missing z-index for .${className}`);
  return Number(match[1]);
}

function extractClassBlock(css: string, className: string): string {
  const match = css.match(new RegExp(`\\.${className}\\s*\\{([\\s\\S]*?)\\n\\}`));
  if (!match) throw new Error(`Missing .${className}`);
  return match[1];
}

describe('ChatView a user-owned provider style contract', () => {
  it('does not keep legacy a user-owned provider disclosure styles after the single-card simplification', () => {
    const css = readChatViewStyles();

    expect(css).not.toContain('.freeDisclosure');
    expect(css).not.toContain('free-disclosure');
  });
});

describe('ChatView overlay layering contract', () => {
  it('keeps the model switcher above the docked composer layer', () => {
    const switcherZIndex = extractClassZIndex(readChatViewStyles(), 'modelSwitcherLayer');
    const composerZIndex = extractClassZIndex(readInputComposerStyles(), 'wrap');

    expect(switcherZIndex).toBeGreaterThan(composerZIndex);
  });

  it('anchors the model switcher layer to the chat view instead of the full viewport', () => {
    const block = extractClassBlock(readChatViewStyles(), 'modelSwitcherLayer');

    expect(block).toContain('position: absolute;');
    expect(block).toContain('inset: 0;');
    expect(block).toContain('pointer-events: none;');
  });

  it('keeps the top bar theme toggle flat and borderless', () => {
    const block = extractClassBlock(readChatViewStyles(), 'themeToggleBtn');

    expect(block).toContain('border: none;');
    expect(block).toContain('background: transparent;');
    expect(block).not.toContain('box-shadow');
  });
});

describe('single model-controls panel layout contract', () => {
  it('uses theme tokens and a logical RTL-safe anchor', () => {
    const block = extractClassBlock(readInputComposerStyles(), 'modelControlsPopover');

    expect(block).toContain('inset-inline-start: 8px;');
    expect(block).not.toMatch(/\bleft:/);
    expect(block).toContain('background: var(--o-surface);');
    expect(block).toContain('border: 1px solid var(--o-border-strong);');
  });

  it('keeps the section list scrollable and the Close footer outside it', () => {
    const css = readInputComposerStyles();
    const sections = extractClassBlock(css, 'modelControlSections');
    const footer = extractClassBlock(css, 'modelControlsFooter');
    const closeBar = extractClassBlock(css, 'modelControlsCloseBar');

    expect(sections).toContain('overflow-y: auto;');
    //  W3  
    //  
    expect(footer).toContain('flex: 0 0 auto;');
    expect(footer).toContain('flex-direction: column;');
    expect(closeBar).toContain('border-top: 1px solid var(--o-border);');
  });

  it('fits narrow screens and safe areas without clipping the panel', () => {
    const css = readInputComposerStyles();
    expect(css).toMatch(/@media \(max-width: 767px\)[\s\S]*?\.modelControlsPopover\s*\{[\s\S]*?width: calc\(100% - 8px\);/);
    expect(css).toContain('--o-model-options-popover-reserved: calc(180px + env(safe-area-inset-bottom, 0px));');
    expect(css).toContain('max-height: calc(100dvh - var(--o-model-options-popover-reserved));');
  });
});
