import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ManualModelPage from './page';

const mocks = vi.hoisted(() => ({
  routerPush: vi.fn(),
  routerBack: vi.fn(),
  addManualProviderModels: vi.fn(),
  getVanillaStore: vi.fn(),
  setHasCompletedOnboarding: vi.fn(),
}));

type MockProvider = {
  id: string;
  kind: string;
  customName?: string;
  models: Array<{ id: string }>;
};

type MockState = {
  providers: MockProvider[];
  setHasCompletedOnboarding: (value: boolean) => void;
};

let mockState: MockState = {
  providers: [],
  setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
};
let mockContext: string | null = null;

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    push: mocks.routerPush,
    back: mocks.routerBack,
  }),
  useParams: () => ({
    providerId: 'provider-1',
  }),
  useSearchParams: () => new URLSearchParams(mockContext ? `context=${mockContext}` : ''),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, string>) =>
    values?.provider ? `${key}:${values.provider}` : key,
}));

vi.mock('@oriveo/config', () => ({
  getProviderDisplayName: () => 'OpenAI',
}));

vi.mock('../../../../components/ProviderIcon', () => ({
  ProviderIcon: ({ kind }: { kind: string }) => <span data-testid={`provider-icon-${kind}`}>{kind}</span>,
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => mocks.getVanillaStore(),
}));

vi.mock('../../../../lib/core/provider-model-ops', () => ({
  addManualProviderModels: (...args: unknown[]) => mocks.addManualProviderModels(...args),
}));

vi.mock('@oriveo/ui', () => ({
  Button: ({
    children,
    onClick,
    disabled,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
  }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Input: ({
    label,
    placeholder,
    value,
    onChange,
    onKeyDown,
  }: {
    label: string;
    placeholder?: string;
    value?: string;
    onChange?: (event: { target: { value: string } }) => void;
    onKeyDown?: (event: { key: string; preventDefault: () => void }) => void;
  }) => (
    <label>
      {label}
      <input
        value={value}
        placeholder={placeholder}
        onChange={(event) => onChange?.({ target: { value: event.target.value } })}
        onKeyDown={(event) =>
          onKeyDown?.({
            key: event.key,
            preventDefault: () => event.preventDefault(),
          })}
      />
    </label>
  ),
}));

describe('ManualModelPage', () => {
  beforeEach(() => {
    mocks.routerPush.mockReset();
    mocks.routerBack.mockReset();
    mocks.addManualProviderModels.mockReset();
    mocks.getVanillaStore.mockReset();
    mocks.setHasCompletedOnboarding.mockReset();
    mocks.getVanillaStore.mockReturnValue({ store: 'vanilla' });
    mockContext = null;
    mockState = {
      providers: [],
      setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    };
  });

  it('shows the missing-provider state and routes back to providers', () => {
    render(<ManualModelPage />);

    expect(screen.getByText('providerNotFound')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'back' }));

    expect(mocks.routerPush).toHaveBeenCalledWith('/providers');
  });

  it('adds a trimmed manual model and returns a normal provider flow to its detail page', () => {
    mockState = {
      providers: [
        {
          id: 'provider-1',
          kind: 'openAI',
          models: [],
        },
      ],
      setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    };

    render(<ManualModelPage />);

    fireEvent.change(screen.getByPlaceholderText('modelIdPlaceholder'), {
      target: { value: '  gpt-4.1-mini  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'saveAndChat' }));

    expect(mocks.addManualProviderModels).toHaveBeenCalledWith(
      { store: 'vanilla' },
      mockState.providers[0],
      ['gpt-4.1-mini'],
    );
    expect(mocks.routerPush).toHaveBeenCalledWith('/providers/provider-1');
    expect(mocks.setHasCompletedOnboarding).not.toHaveBeenCalled();
  });

  it('preserves onboarding context, completes onboarding and routes to chat', () => {
    mockContext = 'onboarding';
    mockState = {
      providers: [{ id: 'provider-1', kind: 'relay', models: [] }],
      setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    };

    render(<ManualModelPage />);
    fireEvent.change(screen.getByPlaceholderText('modelIdPlaceholder'), {
      target: { value: 'relay-model' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'saveAndChat' }));

    expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
    expect(mocks.routerPush).toHaveBeenCalledWith('/chat');
  });

  it('goes back when the secondary action is pressed', () => {
    mockState = {
      providers: [
        {
          id: 'provider-1',
          kind: 'openAI',
          models: [],
        },
      ],
      setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
    };

    render(<ManualModelPage />);

    fireEvent.click(screen.getByRole('button', { name: 'back' }));
    expect(mocks.routerBack).toHaveBeenCalled();
  });
});
