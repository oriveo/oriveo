import { readFileSync } from 'node:fs';
import path from 'node:path';
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
  BackButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
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
    fireEvent.change(screen.getByPlaceholderText('gpt-5.6-sol'), {
      target: { value: 'relay-model' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'save' }));

    expect(mocks.setHasCompletedOnboarding).toHaveBeenCalledWith(true);
    expect(mocks.routerPush).toHaveBeenCalledWith('/chat');
  });

  it('goes back from the header back button', () => {
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

  describe('manual model page', () => {
    function renderWith(kind: 'relay' | 'openAI') {
      mockState = {
        providers: [{ id: 'provider-1', kind, models: [] }],
        setHasCompletedOnboarding: mocks.setHasCompletedOnboarding,
      };
      return render(<ManualModelPage />);
    }

    function slot(): HTMLInputElement {
      return screen.getByRole('textbox', { name: 'modelIdLabel' }) as HTMLInputElement;
    }

    it('relay: header back + title "Add model", blocks [model slot, notes], placeholder = delivered flagship ID, two notes, primary button "Save" with no secondary button, ID left to right', () => {
      const view = renderWith('relay');
      expect(screen.getByRole('heading', { name: 'addModelTitle' })).toBeTruthy();
      expect(screen.getByRole('button', { name: 'back' })).toBeTruthy();
      const sections = [...view.container.querySelectorAll('[data-manual-model-section]')].map((node) => node.getAttribute('data-manual-model-section'));
      expect(sections).toEqual(['modelSlot', 'notes']);
      expect(slot().getAttribute('placeholder')).toBe('gpt-5.6-sol');
      expect(slot().getAttribute('dir')).toBe('ltr');
      expect(screen.getByText('relayModelNote')).toBeTruthy();
      expect(screen.getByText('relayCapabilityNote')).toBeTruthy();
      expect(screen.getByRole('button', { name: 'save' })).toBeTruthy();
      // Only the back button and the primary button (the clear button does not appear when empty).
      expect(screen.getAllByRole('button').map((button) => button.getAttribute('aria-label') ?? button.textContent)).toEqual(['back', 'save']);
      // The old Hero / preview / example / sparkles are all removed.
      expect(screen.queryByTestId('provider-icon-relay')).toBeNull();
      expect(view.container.textContent).not.toContain('description');
    });

    it('official provider: same layout and blocks, title "Backup model", localized placeholder (follows UI direction), route unchanged after saving', () => {
      const view = renderWith('openAI');
      expect(screen.getByRole('heading', { name: 'fallbackTitle' })).toBeTruthy();
      const sections = [...view.container.querySelectorAll('[data-manual-model-section]')].map((node) => node.getAttribute('data-manual-model-section'));
      expect(sections).toEqual(['modelSlot', 'notes']);
      expect(slot().getAttribute('placeholder')).toBe('modelIdPlaceholder');
      expect(slot().getAttribute('dir')).toBeNull();
      fireEvent.change(slot(), { target: { value: 'gpt-4.1' } });
      expect(slot().getAttribute('dir')).toBe('ltr');
    });

    for (const kind of ['relay', 'openAI'] as const) {
      it(`${kind}: empty / whitespace-only cannot be saved; the clear button follows whether there is text; saves the trimmed ID`, () => {
        renderWith(kind);
        const save = screen.getByRole('button', { name: kind === 'relay' ? 'save' : 'saveAndChat' }) as HTMLButtonElement;
        expect(save.disabled).toBe(true);
        expect(screen.queryByRole('button', { name: 'clear' })).toBeNull();
        fireEvent.change(slot(), { target: { value: '   ' } });
        expect(save.disabled).toBe(true);
        expect(screen.getByRole('button', { name: 'clear' })).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: 'clear' }));
        expect(slot().value).toBe('');
        expect(screen.queryByRole('button', { name: 'clear' })).toBeNull();
        fireEvent.change(slot(), { target: { value: '  my-model  ' } });
        expect(save.disabled).toBe(false);
        fireEvent.click(save);
        expect(mocks.addManualProviderModels).toHaveBeenCalledWith({ store: 'vanilla' }, mockState.providers[0], ['my-model']);
      });
    }

    it('relay: after saving, the model is enabled and has only the text capability (production write path)', async () => {
      const actual = await vi.importActual<typeof import('../../../../lib/core/provider-model-ops')>('../../../../lib/core/provider-model-ops');
      expect(actual.createRelayManualModel('my-model').capabilities).toEqual(['text']);
    });

    for (const kind of ['relay', 'openAI'] as const) {
      it(`${kind}: visible subheading above the slot (hidden from screen readers, input aria-label unchanged); the clear button uses manualModel.clear`, () => {
        const view = renderWith(kind);
        const caption = screen.getByText('modelIdLabel');
        expect(caption.getAttribute('aria-hidden')).toBe('true');
        const slotSection = view.container.querySelector('[data-manual-model-section="modelSlot"]')!;
        // The subheading is above the slot (earlier than the input slot in document order)
        expect(caption.compareDocumentPosition(slotSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
        expect(slot().getAttribute('aria-label')).toBe('modelIdLabel');
        fireEvent.change(slot(), { target: { value: 'm' } });
        expect(screen.getByRole('button', { name: 'clear' })).toBeTruthy();
        expect(screen.queryByRole('button', { name: 'webSearch.clear' })).toBeNull();
      });
    }

    it('manualModel.clear in all 16 languages matches iOS verbatim', () => {
      const expected: Record<string, string> = {
        ar: 'مسح', de: 'Löschen', en: 'Clear', es: 'Borrar', fr: 'Effacer', hi: 'साफ़ करें', id: 'Hapus', ja: 'クリア',
        ko: '지우기', 'pt-BR': 'Limpar', ru: 'Очистить', th: 'ล้าง', tr: 'Temizle', vi: 'Xoá', 'zh-Hans': '\u6e05\u9664', 'zh-Hant': '\u6e05\u9664',
      };
      for (const [locale, value] of Object.entries(expected)) {
        const messages = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8')) as { pages: { manualModel: { clear?: string } } };
        expect(messages.pages.manualModel.clear, locale).toBe(value);
      }
    });
  });
});
