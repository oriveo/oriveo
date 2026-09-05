// @vitest-environment jsdom

import React from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import { ConflictCopyGroup } from './ConflictCopyGroup';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'copy-1',
    title: '🔀 Conflict sample',
    hasCustomTitle: false,
    providerID: 'provider-1',
    providerKind: 'openAI',
    modelID: 'model-1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-04-19T10:00:00.000Z',
    updatedAt: '2026-04-19T10:00:00.000Z',
    isConflictCopy: true,
    conflictOriginId: 'orig-1',
    ...overrides,
  };
}

describe('ConflictCopyGroup', () => {
  afterEach(() => {
    cleanup();
  });

  it('returns null when no conflict copies', () => {
    const { container } = render(<ConflictCopyGroup conversations={[]} />);
    expect(container.firstChild).toBeNull();
  });

  it('onCopyAsNew fires with the selected conversation', () => {
    const onCopyAsNew = vi.fn();
    const coachmarkStorage = { read: () => true, write: vi.fn() };
    render(
      <ConflictCopyGroup
        conversations={[makeConversation()]}
        onCopyAsNew={onCopyAsNew}
        coachmarkStorage={coachmarkStorage}
      />,
    );

    // Expand
    fireEvent.click(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ }));
    // Click "copy as a new conversation"
    fireEvent.click(screen.getByRole('button', { name: 'syncMerge.conflictCopy.copyAsNew' }));

    expect(onCopyAsNew).toHaveBeenCalledTimes(1);
    expect(onCopyAsNew).toHaveBeenCalledWith(expect.objectContaining({ id: 'copy-1' }));
  });

  it('onCleanup requires a second confirmation', async () => {
    const onCleanup = vi.fn().mockResolvedValue(undefined);
    const coachmarkStorage = { read: () => true, write: vi.fn() };
    render(
      <ConflictCopyGroup
        conversations={[makeConversation()]}
        onCleanup={onCleanup}
        coachmarkStorage={coachmarkStorage}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ }));
    // Click cleanup - nothing is deleted yet, a confirmation layer should appear first
    fireEvent.click(screen.getByRole('button', { name: 'syncMerge.conflictCopy.cleanup' }));
    expect(onCleanup).not.toHaveBeenCalled();

    // Clicking the cleanup label a second time inside the layer confirms it
    const confirmButtons = screen.getAllByRole('button', { name: 'syncMerge.conflictCopy.cleanup' });
    // The first is the original button in the list, the second is the one in the confirmation dialog
    fireEvent.click(confirmButtons[confirmButtons.length - 1]);
    await Promise.resolve();
    expect(onCleanup).toHaveBeenCalledTimes(1);
    expect(onCleanup).toHaveBeenCalledWith({ exportBeforeCleanup: true });
  });

  it('shows the coachmark on first expand and records the dismissal in storage', () => {
    const write = vi.fn();
    const coachmarkStorage = { read: () => false, write };
    render(
      <ConflictCopyGroup
        conversations={[makeConversation()]}
        coachmarkStorage={coachmarkStorage}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ }));
    // The coachmark copy should appear
    expect(screen.getByText('syncMerge.conflictCopy.coachmark.title')).toBeTruthy();
    // Dismiss
    fireEvent.click(screen.getByRole('button', { name: 'syncMerge.confirm.proceed' }));
    expect(write).toHaveBeenCalledTimes(1);
    // Expanding again after dismissal does not show the coachmark because storage is marked; the write call count already covers that
  });

  it('does not show the coachmark again once it has been seen', () => {
    const coachmarkStorage = { read: () => true, write: vi.fn() };
    render(
      <ConflictCopyGroup
        conversations={[makeConversation()]}
        coachmarkStorage={coachmarkStorage}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ }));
    expect(screen.queryByText('syncMerge.conflictCopy.coachmark.title')).toBeNull();
  });

  it('still shows the coachmark when localStorage throws, since the fallback is false', () => {
    // Simulate localStorage.getItem throwing SecurityError, as Safari private mode does
    const originalGetItem = window.localStorage.getItem;
    window.localStorage.getItem = vi.fn(() => {
      throw new DOMException('SecurityError', 'SecurityError');
    });

    try {
      render(<ConflictCopyGroup conversations={[makeConversation()]} />);
      fireEvent.click(screen.getByRole('button', { name: /syncMerge\.conflictCopy\.section/ }));
      // Even with storage unavailable, the first expand should show the coachmark, since this is the user's first encounter with the feature
      expect(screen.getByText('syncMerge.conflictCopy.coachmark.title')).toBeTruthy();
    } finally {
      window.localStorage.getItem = originalGetItem;
    }
  });
});
