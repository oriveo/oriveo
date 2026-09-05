import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { LazyExportMenu, LazyModelSwitcher } from './LazyChatOverlays';

vi.mock('./ModelSwitcher', () => ({
  ModelSwitcher: ({ providers }: { providers: Array<{ id: string }> }) => (
    <div data-testid="model-switcher">{providers.length}</div>
  ),
}));

vi.mock('./ExportMenu', () => ({
  ExportMenu: ({ conversation }: { conversation: { title: string } }) => (
    <div data-testid="export-menu">{conversation.title}</div>
  ),
}));

describe('LazyChatOverlays', () => {
  it('loads ModelSwitcher lazily', async () => {
    render(
      <LazyModelSwitcher
        providers={[{ id: 'provider-1' } as never]}
        onClose={vi.fn()}
        onSelect={vi.fn()}
        onEnableAndSelect={vi.fn()}
        onAddManualAndSelect={vi.fn()}
      />,
    );

    expect(screen.queryByTestId('model-switcher')).toBeNull();
    await waitFor(() => expect(screen.getByTestId('model-switcher').textContent).toBe('1'));
  });

  it('loads ExportMenu lazily', async () => {
    render(
      <LazyExportMenu
        conversation={{ title: 'Test Conversation' } as never}
        onClose={vi.fn()}
      />,
    );

    expect(screen.queryByTestId('export-menu')).toBeNull();
    await waitFor(() => expect(screen.getByTestId('export-menu').textContent).toBe('Test Conversation'));
  });
});
