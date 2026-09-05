// @vitest-environment jsdom
import { render } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';

import { ConversationItem } from '../ConversationItem';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: any) => unknown) =>
    selector({
      providers: [],
      folders: [],
      catalogSkills: [],
      userSkills: [],
    }),
}));

vi.mock('../../../lib/core/providers/model-display-lookup', () => ({
  createModelDisplayLookup: () => ({
    resolve: () => null,
  }),
}));

vi.mock('../../ContextMenu', () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({
    menu: null,
    handleContextMenu: vi.fn(),
    closeMenu: vi.fn(),
  }),
}));

vi.mock('../MoveToFolderMenu', () => ({
  MoveToFolderMenu: () => null,
}));

vi.mock('../../ProviderIcon', () => ({
  ProviderIcon: () => <span data-testid="provider-icon" />,
}));

function makeConversation(): Conversation {
  return {
    id: 'conv-1',
    title: 'A Conversation',
    hasCustomTitle: false,
    providerID: 'p-1',
    modelID: 'gpt-4',
    previewText: 'preview',
    estimatedCost: 0,
    isDraft: false,
    messages: [
      {
        id: 'm-1',
        role: 'assistant',
        text: 'hello',
        providerID: 'p-1',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'gpt-4',
        modelName: 'GPT-4',
        state: 'generating',
        estimatedCost: 0,
      },
    ],
    draftText: '',
    updatedAt: '2026-05-07T00:00:00.000Z',
  };
}

const noopHandlers = {
  onSelect: vi.fn(),
  onRename: vi.fn(),
  onDelete: vi.fn(),
};

describe('ConversationItem streaming pulse dot', () => {
  it('renders the status marker when isStreaming=true', () => {
    const conv = makeConversation();
    const { container, queryByRole } = render(
      <ConversationItem
        conversation={conv}
        active={false}
        {...noopHandlers}
        isStreaming
      />,
    );
    const dot = queryByRole('status');
    expect(dot).not.toBeNull();
    // Do not depend on the generated module hash; check only the key marker on the inline style and the aria attributes.
    expect(dot?.getAttribute('aria-label')).toBe('generating');
    expect(container).toBeTruthy();
  });

  it('renders no pulse dot when isStreaming is false or absent', () => {
    const conv = makeConversation();
    const { queryByRole } = render(
      <ConversationItem
        conversation={conv}
        active={false}
        {...noopHandlers}
      />,
    );
    expect(queryByRole('status')).toBeNull();
  });
});
