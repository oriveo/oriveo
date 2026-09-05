import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { CrosscheckSheet } from './CrosscheckSheet';

function cssClassBlock(css: string, className: string): string {
  const start = css.indexOf(`.${className} {`);
  if (start === -1) return '';
  const open = css.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < css.length; i += 1) {
    if (css[i] === '{') depth += 1;
    if (css[i] === '}') {
      depth -= 1;
      if (depth === 0) return css.slice(start, i + 1);
    }
  }
  return '';
}

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: vi.fn() }),
}));

vi.mock('next-intl', () => ({
  useTranslations: (namespace: string) => (key: string) => `${namespace}.${key}`,
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    tone: _tone,
    size: _size,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    tone?: string;
    size?: string;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
}));

vi.mock('./MarkdownRenderer', () => ({
  MarkdownRenderer: ({ content }: { content: string }) => <div data-testid="markdown-renderer">{content}</div>,
}));

vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => ({ getState: () => ({}) }),
  useAppStore: <T,>(selector: (state: { sidebarOpen: boolean; preferences: { language: string } }) => T) =>
    selector({ sidebarOpen: true, preferences: { language: 'en' } }),
}));

vi.mock('../../lib/core/note-ai-ops', () => ({
  crosscheckAnswer: vi.fn(),
}));

vi.mock('../../lib/core/note-ops', () => ({
  createNoteFromCrosscheck: vi.fn(),
}));

vi.mock('../notes/note-toast', () => ({
  showSavedNoteToast: vi.fn(),
}));

const textModel: AIModel = {
  id: 'gpt-4o',
  name: 'GPT-4o',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '$',
};

function provider(overrides: Partial<Provider>): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    apiKey: 'sk-test',
    apiKeyPreview: 'sk...test',
    models: [textModel],
    catalogModels: [],
    ...overrides,
  };
}

const conversation: Conversation = {
  id: 'conv-1',
  title: 'Chat',
  hasCustomTitle: false,
  providerID: 'provider-origin',
  providerKind: 'openAI',
  modelID: 'gpt-4o',
  previewText: '',
  estimatedCost: 0,
  isDraft: false,
  messages: [],
  draftText: '',
  createdAt: '2026-06-19T00:00:00.000Z',
  updatedAt: '2026-06-19T00:00:00.000Z',
};

const originMessage: ChatMessage = {
  id: 'assistant-1',
  role: 'assistant',
  text: 'Original answer',
  providerID: 'provider-origin',
  providerKind: 'openAI',
  providerName: 'OpenAI',
  modelID: 'gpt-4o',
  modelName: 'GPT-4o',
  state: 'delivered',
  estimatedCost: 0,
  createdAt: '2026-06-19T00:00:00.000Z',
};

describe('CrosscheckSheet', () => {
  it('keeps the sheet and model menu opaque instead of glassy', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.module.css'), 'utf8');

    expect(cssClassBlock(css, 'sheet')).toContain('background: var(--o-surface);');
    expect(cssClassBlock(css, 'modelMenu')).toContain('background: var(--o-surface);');
    expect(cssClassBlock(css, 'modelMenu')).toContain('width: min(520px, 100%);');
    expect(cssClassBlock(css, 'modelMenu')).not.toContain('right: 0;');
    expect(cssClassBlock(css, 'modelMenu')).not.toContain('backdrop-filter');
  });

  it('uses the modal layer behavior from the design system instead of a loose overlay', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.module.css'), 'utf8');

    expect(cssClassBlock(css, 'layer')).toContain('z-index: 100;');
    expect(cssClassBlock(css, 'backdrop')).toContain('background: var(--o-overlay);');
    expect(cssClassBlock(css, 'sheet')).toContain('width: min(1080px, 100%);');
    expect(cssClassBlock(css, 'sheet')).toContain('height: min(760px, calc(100dvh - 48px));');
    expect(cssClassBlock(css, 'closeButton')).toContain('min-width: var(--o-touch-target);');
    expect(cssClassBlock(css, 'closeButton')).toContain('min-height: var(--o-touch-target);');
  });

  it('keeps the model picker and run button on the same control baseline', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.module.css'), 'utf8');

    expect(cssClassBlock(css, 'controls')).toContain('display: grid;');
    expect(cssClassBlock(css, 'controls')).toContain('grid-template-columns: minmax(0, 1fr) auto;');
    expect(cssClassBlock(css, 'runButtonWrap')).toContain('align-items: end;');
    expect(cssClassBlock(css, 'runButtonWrap button')).toContain('min-height: 48px;');
  });

  it('keeps the mobile model picker menu in normal sheet flow instead of covering answers', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.module.css'), 'utf8');
    const mobileStart = css.indexOf('@media (max-width: 720px)');
    const mobileCss = mobileStart >= 0 ? css.slice(mobileStart) : '';

    expect(mobileCss).toContain('.modelMenu');
    expect(mobileCss).toContain('position: static;');
    expect(mobileCss).toContain('box-shadow: var(--o-elevation-card);');
    expect(mobileCss).toContain('padding-bottom: calc(16px + env(safe-area-inset-bottom));');
  });

  it('does not indent the cross-check answer copy with a leading icon', () => {
    const css = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.module.css'), 'utf8');
    const source = readFileSync(join(process.cwd(), 'components/chat/CrosscheckSheet.tsx'), 'utf8');

    expect(source).toContain('ChevronDown');
    expect(source).not.toContain('className={styles.answerInlineIcon}');
    expect(source).not.toContain('className={styles.answerWithIcon}');
    expect(cssClassBlock(css, 'answerWithIcon')).toBe('');
    expect(cssClassBlock(css, 'answerInlineIcon')).toBe('');
    expect(cssClassBlock(css, 'answerBody')).toBe('');
  });

  it('renders original and cross-check answers through the chat markdown renderer', async () => {
    const { crosscheckAnswer } = await import('../../lib/core/note-ai-ops');
    vi.mocked(crosscheckAnswer).mockResolvedValue({ text: '**Crosscheck verdict**\n\n- second point' });
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const userProvider = provider({
      id: 'provider-user',
      customName: 'Other key',
      models: [{ ...textModel, id: 'gpt-4.1', name: 'GPT-4.1' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer={'**Original answer**\n\n- first point'}
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, userProvider]}
        onClose={vi.fn()}
      />,
    );

    let renderedMarkdown = screen.getAllByTestId('markdown-renderer').map((node) => node.textContent);
    expect(renderedMarkdown).toContain('**Original answer**\n\n- first point');
    expect(renderedMarkdown).not.toContain('notes.crosscheck.empty');

    fireEvent.click(screen.getByRole('button', { name: 'notes.crosscheck.run' }));
    await waitFor(() => {
      renderedMarkdown = screen.getAllByTestId('markdown-renderer').map((node) => node.textContent);
      expect(renderedMarkdown).toContain('**Crosscheck verdict**\n\n- second point');
    });

    expect(renderedMarkdown).toContain('**Original answer**\n\n- first point');
  });

  it('excludes keyless BYOK providers from the model menu', () => {
    const originProvider = provider({ id: 'provider-origin' });
    const userProvider = provider({
      id: 'provider-user',
      customName: 'My OpenAI key',
      models: [{ ...textModel, id: 'gpt-4.1', name: 'GPT-4.1' }],
    });
    const keylessByokProvider = provider({
      id: 'provider-keyless',
      kind: 'anthropic',
      customName: 'Keyless Anthropic',
      apiKey: '',
      apiKeyPreview: '',
      models: [{ ...textModel, id: 'claude-keyless', name: 'Claude Keyless' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[keylessByokProvider, originProvider, userProvider]}
        onClose={vi.fn()}
      />,
    );

    const trigger = screen.getByRole('button', { name: /notes\.crosscheck\.model/ });
    fireEvent.click(trigger);
    const listbox = screen.getByRole('listbox');

    expect(within(listbox).getByRole('button', { name: /My OpenAI key/ })).toBeTruthy();
    expect(within(listbox).queryByRole('button', { name: /Keyless Anthropic/ })).toBeNull();

    // The group holding the selected model opens with the menu, so its models are listed without a click.
    expect(within(listbox).getByRole('option', { name: /GPT-4.1/ })).toBeTruthy();
    expect(within(listbox).queryByRole('option', { name: /Claude Keyless/ })).toBeNull();
  });

  it('uses an in-app model menu instead of the native select popup', () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const firstProvider = provider({
      id: 'provider-first',
      customName: 'OpenRouter',
      models: [{ ...textModel, id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' }],
    });
    const secondProvider = provider({
      id: 'provider-second',
      customName: 'DeepSeek',
      models: [{ ...textModel, id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, firstProvider, secondProvider]}
        onClose={vi.fn()}
      />,
    );

    expect(screen.queryByRole('combobox')).toBeNull();

    const trigger = screen.getByRole('button', { name: /notes\.crosscheck\.model/ });
    expect(trigger.textContent).toContain('DeepSeek V4 Flash');
    expect(trigger.textContent).toContain('OpenRouter');

    fireEvent.click(trigger);
    const listbox = screen.getByRole('listbox');
    fireEvent.click(within(listbox).getByRole('button', { name: /DeepSeek/ }));
    const secondOption = within(listbox).getByRole('option', { name: /DeepSeek V4 Pro/ });
    fireEvent.click(secondOption);

    expect(trigger.textContent).toContain('DeepSeek V4 Pro');
    expect(trigger.textContent).toContain('DeepSeek');
  });

  it('closes the in-app model menu when clicking outside the picker', () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const firstProvider = provider({
      id: 'provider-first',
      customName: 'OpenRouter',
      models: [{ ...textModel, id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' }],
    });
    const secondProvider = provider({
      id: 'provider-second',
      customName: 'DeepSeek',
      models: [{ ...textModel, id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, firstProvider, secondProvider]}
        onClose={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /notes\.crosscheck\.model/ }));
    expect(screen.getByRole('listbox')).toBeTruthy();

    fireEvent.pointerDown(screen.getByRole('button', { name: 'notes.crosscheck.run' }));

    expect(screen.queryByRole('listbox')).toBeNull();
  });

  it('keeps a single provider group and only expands the selected vendor initially', () => {
    const originProvider = provider({ id: 'provider-origin' });
    const groupedProvider = provider({
      id: 'provider-grouped',
      kind: 'openAI',
      customName: 'Grouped Provider',
      models: [
        { ...textModel, id: 'gpt-5', name: 'GPT-5', groupKey: 'openai', groupName: 'OpenAI' },
        {
          ...textModel,
          id: 'claude-sonnet',
          name: 'Claude Sonnet',
          groupKey: 'anthropic',
          groupName: 'Anthropic',
        },
      ],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, groupedProvider]}
        onClose={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /notes\.crosscheck\.model/ }));
    const listbox = screen.getByRole('listbox');
    const providerHeader = within(listbox).getByRole('button', { name: /Grouped Provider/ });
    const openAIHeader = within(listbox).getByRole('button', { name: /OpenAI/ });
    const anthropicHeader = within(listbox).getByRole('button', { name: /Anthropic/ });

    expect(providerHeader.getAttribute('aria-expanded')).toBe('true');
    expect(openAIHeader.getAttribute('aria-expanded')).toBe('true');
    expect(anthropicHeader.getAttribute('aria-expanded')).toBe('false');
    expect(within(listbox).getByRole('option', { name: /GPT-5/ })).toBeTruthy();
    expect(within(listbox).queryByRole('option', { name: /Claude Sonnet/ })).toBeNull();

    fireEvent.click(anthropicHeader);
    expect(within(listbox).getByRole('option', { name: /Claude Sonnet/ })).toBeTruthy();
  });

  it('supports keyboard model selection with listbox semantics', () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const firstProvider = provider({
      id: 'provider-first',
      customName: 'OpenRouter',
      models: [{ ...textModel, id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' }],
    });
    const secondProvider = provider({
      id: 'provider-second',
      customName: 'DeepSeek',
      models: [{ ...textModel, id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, firstProvider, secondProvider]}
        onClose={vi.fn()}
      />,
    );

    const trigger = screen.getByRole('button', { name: /notes\.crosscheck\.model/ });
    fireEvent.keyDown(trigger, { key: 'ArrowDown' });
    const listbox = screen.getByRole('listbox');
    expect(listbox.getAttribute('aria-activedescendant')).toContain('provider-first');

    fireEvent.keyDown(listbox, { key: 'ArrowDown' });
    expect(listbox.getAttribute('aria-activedescendant')).toContain('provider-second');
    fireEvent.keyDown(listbox, { key: 'Enter' });

    expect(trigger.textContent).toContain('DeepSeek V4 Pro');
    expect(trigger.textContent).toContain('DeepSeek');
    expect(screen.queryByRole('listbox')).toBeNull();
  });

  it('keeps the listbox as one composite tab stop with selected value announced by the trigger', () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const firstProvider = provider({
      id: 'provider-first',
      customName: 'OpenRouter',
      models: [{ ...textModel, id: 'deepseek-v4-flash', name: 'DeepSeek V4 Flash' }],
    });
    const secondProvider = provider({
      id: 'provider-second',
      customName: 'DeepSeek',
      models: [{ ...textModel, id: 'deepseek-v4-pro', name: 'DeepSeek V4 Pro' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, firstProvider, secondProvider]}
        onClose={vi.fn()}
      />,
    );

    const trigger = screen.getByRole('button', {
      name: /notes\.crosscheck\.model.*DeepSeek V4 Flash.*OpenRouter/,
    });
    expect(trigger.getAttribute('aria-label')).toBeNull();

    fireEvent.click(trigger);
    const listbox = screen.getByRole('listbox');
    expect(document.activeElement).toBe(listbox);

    for (const option of screen.getAllByRole('option')) {
      expect(option.getAttribute('tabindex')).toBe('-1');
    }
  });

  it('keeps the model menu open when scrolling inside the listbox and Escape only closes the menu first', () => {
    const onClose = vi.fn();
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const userProvider = provider({
      id: 'provider-user',
      customName: 'Many models',
      models: Array.from({ length: 8 }, (_, index) => ({
        ...textModel,
        id: `model-${index}`,
        name: `Model ${index}`,
      })),
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, userProvider]}
        onClose={onClose}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /notes\.crosscheck\.model/ }));
    const listbox = screen.getByRole('listbox');
    fireEvent.scroll(listbox);
    expect(screen.getByRole('listbox')).toBeTruthy();

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('listbox')).toBeNull();
    expect(onClose).not.toHaveBeenCalled();

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('traps focus in the modal and restores body scroll after close', () => {
    const onClose = vi.fn();
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    const userProvider = provider({
      id: 'provider-user',
      customName: 'My OpenAI key',
      models: [{ ...textModel, id: 'gpt-4.1', name: 'GPT-4.1' }],
    });
    const opener = document.createElement('button');
    opener.textContent = 'open sheet';
    document.body.append(opener);
    opener.focus();

    const { unmount } = render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, userProvider]}
        onClose={onClose}
      />,
    );

    const dialog = screen.getByRole('dialog', { name: 'notes.crosscheck.title' });
    const closeButton = within(dialog).getAllByRole('button', { name: 'notes.crosscheck.close' })[0];
    const footerCloseButton = within(dialog).getAllByRole('button', { name: 'notes.crosscheck.close' })[1];
    expect(document.body.style.overflow).toBe('hidden');

    closeButton.focus();
    fireEvent.keyDown(dialog, { key: 'Tab', shiftKey: true });
    expect(document.activeElement).toBe(footerCloseButton);

    footerCloseButton.focus();
    fireEvent.keyDown(dialog, { key: 'Tab' });
    expect(document.activeElement).toBe(closeButton);

    opener.focus();
    fireEvent.keyDown(dialog, { key: 'Tab' });
    expect(document.activeElement).toBe(closeButton);

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);

    unmount();
    expect(document.body.style.overflow).toBe('');
    expect(document.activeElement).toBe(opener);
    opener.remove();
  });

  it('portals the modal to document.body instead of the message row container', () => {
    const originProvider = provider({ id: 'provider-origin' });
    const userProvider = provider({
      id: 'provider-user',
      customName: 'My OpenAI key',
      models: [{ ...textModel, id: 'gpt-4.1', name: 'GPT-4.1' }],
    });

    const { container } = render(
      <div data-testid="message-row">
        <CrosscheckSheet
          open
          conversation={conversation}
          originMessage={originMessage}
          originalPrompt="Original prompt"
          originalAnswer="Original answer"
          originProvider={originProvider}
          originModel={textModel}
          providers={[originProvider, userProvider]}
          onClose={vi.fn()}
        />
      </div>,
    );

    const dialog = screen.getByRole('dialog', { name: 'notes.crosscheck.title' });

    expect(container.contains(dialog)).toBe(false);
    expect(document.body.contains(dialog)).toBe(true);
  });

  it('excludes the origin model from cross-check candidates', async () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });
    // Another instance with the same kind and model (gpt-4o) must be excluded too, since the origin model is removed by kind+modelID
    const sameModelProvider = provider({ id: 'provider-dup', customName: 'Dup key', models: [textModel] });
    const otherProvider = provider({
      id: 'provider-other',
      customName: 'Other key',
      models: [{ ...textModel, id: 'gpt-4.1', name: 'GPT-4.1' }],
    });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider, sameModelProvider, otherProvider]}
        onClose={vi.fn()}
      />,
    );

    const trigger = screen.getByRole('button', { name: /notes\.crosscheck\.model/ });
    fireEvent.click(trigger);
    const listbox = screen.getByRole('listbox');

    expect(within(listbox).queryByRole('option', { name: /GPT-4o/ })).toBeNull();
    expect(within(listbox).getByRole('button', { name: /Other key/ })).toBeTruthy();
    expect(within(listbox).getByRole('option', { name: /GPT-4.1/ })).toBeTruthy();
  });

  it('disables Run and shows guidance when excluding the origin leaves no candidate', () => {
    const originProvider = provider({ id: 'provider-origin', customName: 'Origin key' });

    render(
      <CrosscheckSheet
        open
        conversation={conversation}
        originMessage={originMessage}
        originalPrompt="Original prompt"
        originalAnswer="Original answer"
        originProvider={originProvider}
        originModel={textModel}
        providers={[originProvider]}
        onClose={vi.fn()}
      />,
    );

    // No candidates once the origin model is excluded: no dropdown, a friendly message, and Run disabled
    expect(screen.queryByRole('combobox')).toBeNull();
    expect(screen.getByText('notes.crosscheck.noCandidate')).toBeTruthy();
    const runButton = screen.getByRole('button', { name: 'notes.crosscheck.run' });
    expect((runButton as HTMLButtonElement).disabled).toBe(true);
  });
});
