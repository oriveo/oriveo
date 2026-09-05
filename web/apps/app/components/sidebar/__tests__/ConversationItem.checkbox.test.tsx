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
    openMenu: vi.fn(),
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
    providerKind: 'openAI',
    modelID: 'gpt-4',
    previewText: 'preview',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-05-07T00:00:00.000Z',
    updatedAt: '2026-05-07T00:00:00.000Z',
  };
}

const noopHandlers = {
  onSelect: vi.fn(),
  onRename: vi.fn(),
  onDelete: vi.fn(),
};

describe('ConversationItem edit-mode checkbox a11y', () => {
  it('selected=true gives role=checkbox with aria-checked=true', () => {
    const { getByRole } = render(
      <ConversationItem
        conversation={makeConversation()}
        active={false}
        editMode
        selected
        onToggleSelect={vi.fn()}
        {...noopHandlers}
      />,
    );
    const checkbox = getByRole('checkbox');
    expect(checkbox.getAttribute('aria-checked')).toBe('true');
  });

  it('selected=false gives aria-checked=false', () => {
    const { getByRole } = render(
      <ConversationItem
        conversation={makeConversation()}
        active={false}
        editMode
        selected={false}
        onToggleSelect={vi.fn()}
        {...noopHandlers}
      />,
    );
    const checkbox = getByRole('checkbox');
    expect(checkbox.getAttribute('aria-checked')).toBe('false');
  });

  it('renders no checkbox outside edit mode', () => {
    const { queryByRole } = render(
      <ConversationItem
        conversation={makeConversation()}
        active={false}
        {...noopHandlers}
      />,
    );
    expect(queryByRole('checkbox')).toBeNull();
  });
});
