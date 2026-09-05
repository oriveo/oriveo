import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Settings } from './Settings';
import styles from './Settings.module.css';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  routerRefresh: vi.fn(),
  setPreferences: vi.fn(),
}));

type MockState = {
  account: {
    email: string;
    name: string;
    avatarURL?: string;
  } | null;
  preferences: {
    theme: 'system' | 'light' | 'dark';
    language: string;
    sendShortcut: 'cmdEnter' | 'enter';
    memoryText: string;
  };
  setPreferences: typeof mocks.setPreferences;
};

let mockState: MockState = {
  account: null,
  preferences: {
    theme: 'system',
    language: 'system',
    sendShortcut: 'cmdEnter',
    memoryText: '',
  },
  setPreferences: mocks.setPreferences,
};

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.routerPush,
    refresh: mocks.routerRefresh,
  }),
}));

vi.mock('../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => ({ getState: () => ({}) }),
}));

vi.mock('../../components/MenuSelect', () => ({
  MenuSelect: ({
    ariaLabel,
    options,
  }: {
    ariaLabel: string;
    options: Array<{ value: string; label: string }>;
  }) => (
    <div data-testid={`menu-${ariaLabel}`}>
      {options.map((option) => (
        <span key={`${ariaLabel}-${option.value}`}>{option.label}</span>
      ))}
    </div>
  ),
}));

vi.mock('../../components/common/UserAvatar', () => ({
  UserAvatar: () => <div data-testid="user-avatar" />,
}));

const metadataMock = vi.hoisted(() => {
  const state = {
    enabled: true,
    version: 0,
    listeners: new Set<() => void>(),
  };
  return {
    state,
    isRuntimeFeatureEnabled: vi.fn(() => state.enabled),
  };
});
vi.mock('../../lib/core/metadata/metadata-client', () => ({
  isRuntimeFeatureEnabled: metadataMock.isRuntimeFeatureEnabled,
  onVersionChange: (listener: () => void) => {
    metadataMock.state.listeners.add(listener);
    return () => {
      metadataMock.state.listeners.delete(listener);
    };
  },
  getCachedMetadataVersion: () => metadataMock.state.version,
}));

describe('Settings', () => {
  beforeEach(() => {
    mocks.routerPush.mockReset();
    mocks.routerRefresh.mockReset();
    mocks.setPreferences.mockReset();
    mockState = {
      account: null,
      preferences: {
        theme: 'system',
        language: 'system',
        sendShortcut: 'cmdEnter',
        memoryText: '',
      },
      setPreferences: mocks.setPreferences,
    };
    metadataMock.state.enabled = true;
    metadataMock.state.version = 0;
    metadataMock.state.listeners.clear();
    metadataMock.isRuntimeFeatureEnabled.mockReset();
    metadataMock.isRuntimeFeatureEnabled.mockImplementation(() => metadataMock.state.enabled);
  });

  it('renders the newly supported language options with native labels', () => {
    render(<Settings />);

    expect(screen.getByText('हिन्दी')).toBeTruthy();
    expect(screen.getByText('Bahasa Indonesia')).toBeTruthy();
    expect(screen.getByText('Tiếng Việt')).toBeTruthy();
    expect(screen.getByText('ไทย')).toBeTruthy();
    expect(screen.getByText('Türkçe')).toBeTruthy();
    expect(screen.getByText('Русский')).toBeTruthy();
  });

  it('renders memory content in the trailing area instead of the title column', () => {
    mockState.preferences.memoryText = 'Keep answers concise';

    const { container } = render(<Settings />);

    const memoryRow = screen
      .getByText('settingsEntry')
      .closest(`.${styles.navRow}`);

    expect(memoryRow).toBeTruthy();

    const infoColumn = memoryRow?.querySelector(`.${styles.navRowInfo}`);
    const trailingArea = memoryRow?.querySelector(`.${styles.navRowTrailing}`);

    expect(infoColumn).toBeTruthy();
    expect(infoColumn?.textContent).toContain('settingsEntry');
    expect(infoColumn?.textContent).not.toContain('Keep answers concise');

    expect(trailingArea).toBeTruthy();
    expect(trailingArea?.textContent).toContain('Keep answers concise');
    expect(container.querySelector(`.${styles.navRowTrailing}`)).toBeTruthy();
  });

  it('does not render a new badge on the AI section when memory has not been seen', () => {
    window.localStorage.removeItem('oriveo.memory.seen');

    render(<Settings />);

    expect(screen.getByRole('heading', { name: 'aiSection' }).childElementCount).toBe(0);
  });

  // --- No global developer gate -------------------------------
  //
  // A single global key cannot govern a pile of settings stored per
  // connection x model x transport: the user could never tell whether a given connection was on.
  // The entry for custom request fields is model options -> advanced settings -> developer, and
  // the only condition for sending is that the setting itself is set to custom.
  it('has no developer gate on the settings page, and an old key already set does not revive one', () => {
    localStorage.setItem('oriveo.local-custom-fragment-developer-mode.v1', 'true');

    render(<Settings />);

    expect(screen.queryAllByRole('switch')).toHaveLength(0);
    expect(screen.queryByText('customRequestFieldsCustom')).toBeNull();
    expect(screen.queryByText('customRequestFieldsEnableScope')).toBeNull();
  });
});
