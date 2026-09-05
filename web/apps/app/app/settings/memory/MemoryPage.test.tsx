import type { ReactNode } from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryPage } from './MemoryPage';

type MockPreferences = {
  memoryText?: string;
  memoryAntiForgetEnabled?: boolean;
  memoryAntiForgetText?: string;
};

type MockProvider = {
  models: Array<{ id: string }>;
};

type MockConversation = {
  isDraft?: boolean;
  updatedAt: string;
  messages: Array<{
    state: string;
    role: string;
    text: string;
  }>;
};

type MockMemoryState = {
  preferences: MockPreferences;
  memoryUsageCount: number;
  providers: MockProvider[];
  conversations: MockConversation[];
};

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  updateMemory: vi.fn(),
  sendStream: vi.fn(),
  readStream: vi.fn(),
  showToast: vi.fn(),
  vanillaStore: { getState: vi.fn() },
}));

let mockState: MockMemoryState = {
  preferences: {},
  memoryUsageCount: 0,
  providers: [],
  conversations: [],
};

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.routerPush,
  }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockMemoryState) => unknown) => selector(mockState),
  getVanillaStore: () => mocks.vanillaStore,
}));

vi.mock('../../../lib/core/preference-ops', () => ({
  updateMemory: (...args: unknown[]) => mocks.updateMemory(...args),
}));

vi.mock('../../../lib/core/providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../lib/utils/chat-stream-utils', () => ({
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));

vi.mock('../../../components/Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
  }: {
    children: ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Dialog: ({
    open,
    onClose,
    children,
  }: {
    open: boolean;
    onClose?: () => void;
    children: ReactNode;
  }) => (
    open ? (
      <div>
        <button type="button" onClick={onClose}>close-dialog</button>
        {children}
      </div>
    ) : null
  ),
}));

describe('MemoryPage', () => {
  beforeEach(() => {
    mockState = {
      preferences: {},
      memoryUsageCount: 0,
      providers: [],
      conversations: [],
    };
    mocks.routerPush.mockReset();
    mocks.updateMemory.mockReset();
    mocks.sendStream.mockReset();
    mocks.readStream.mockReset();
    mocks.showToast.mockReset();
    mocks.vanillaStore.getState.mockReset();
    mocks.sendStream.mockReturnValue({ stream: {} });
    mocks.readStream.mockResolvedValue({ fullText: 'Generated draft' });
  });

  it('shows the starter card with CTA actions when memory is empty', () => {
    render(<MemoryPage />);

    // Starter state: page title, the emptyTitle heading and the manualWrite primary CTA when there are no recent conversations; the editor textarea is not rendered yet
    expect(screen.getByText('emptyTitle')).toBeTruthy();
    expect(screen.getByRole('button', { name: /manualWrite/i })).toBeTruthy();
    expect(screen.queryByPlaceholderText('exampleHint')).toBeNull();
  });

  it('saves edited memory via preference ops', async () => {
    // With existing memory content, go straight into editor mode without tapping manualWrite
    mockState = {
      ...mockState,
      preferences: { memoryText: 'Existing memory' },
    };
    render(<MemoryPage />);

    fireEvent.change(screen.getByPlaceholderText('exampleHint'), {
      target: { value: 'Remember that I prefer concise answers.' },
    });

    fireEvent.click(screen.getByRole('button', { name: 'save' }));

    await waitFor(() => {
      expect(mocks.updateMemory).toHaveBeenCalledWith(
        mocks.vanillaStore,
        'Remember that I prefer concise answers.',
        false,
        '',
      );
    });
    expect(screen.getByText('saved')).toBeTruthy();
  });

  it('prompts before leaving with unsaved changes and can discard', async () => {
    mockState = {
      ...mockState,
      preferences: { memoryText: 'Existing memory' },
    };
    render(<MemoryPage />);

    fireEvent.change(screen.getByPlaceholderText('exampleHint'), {
      target: { value: 'Unsaved draft' },
    });

    fireEvent.click(screen.getByRole('button', { name: /backToSettings/i }));

    await waitFor(() => {
      expect(screen.getByText('unsavedChanges')).toBeTruthy();
    });

    fireEvent.click(screen.getByRole('button', { name: 'discard' }));

    expect(mocks.routerPush).toHaveBeenCalledWith('/settings');
  });
});
