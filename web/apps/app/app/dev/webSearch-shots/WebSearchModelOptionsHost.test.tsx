import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';

vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string, values?: Record<string, unknown>) => (
    values ? `${namespace}.${key}:${Object.values(values).join(',')}` : `${namespace}.${key}`
  ),
  useLocale: () => 'en',
}));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: <T,>(selector: (state: { providers: never[] }) => T) => selector({ providers: [] }),
  tryGetVanillaStore: () => null,
}));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: vi.fn() }));

function loadManifest() {
  for (let dir = resolve(import.meta.dirname); ; dir = dirname(dir)) {
    try {
      return JSON.parse(readFileSync(join(dir, 'shared', 'test-fixtures', 'shots', 'webSearch.v1.json'), 'utf8'));
    } catch (error) {
      if (dirname(dir) === dir) throw error;
    }
  }
}

describe('webSearch shots: model options host (production ModelOptionsPopover)', () => {
  // Cold transpilation of the production panel is slow: load it once up front so it does not eat the test budget.
  beforeAll(async () => {
    await import('./webSearch-shots-data');
    await import('./WebSearchModelOptionsHost');
  }, 60_000);
  afterEach(() => cleanup());

  async function renderShot(page: string) {
    const data = await import('./webSearch-shots-data');
    const { WebSearchModelOptionsHost } = await import('./WebSearchModelOptionsHost');
    const shot = data.webSearchShotPlan(page as never, loadManifest()).modelOptions!;
    render(<WebSearchModelOptionsHost shot={shot} />);
  }

  it('webSearchOptNotArmed: external never tapped → switch off "Off · DeepSeek search available"; tapping it takes effect, switching service goes into "Search method"', async () => {
    await renderShot('webSearchOptNotArmed');
    const toggle = screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement;
    expect(toggle.checked).toBe(false);
    expect(screen.getByText('undefined.webSearch.card.offUseService:DeepSeek')).toBeTruthy();
    fireEvent.click(toggle);
    expect((screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement).checked).toBe(true);
    expect(screen.getByText('undefined.webSearch.card.useService:DeepSeek')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'undefined.webSearch.card.changeService' }));
    expect(screen.getByTestId('search-source-picker')).toBeTruthy();
    expect(screen.getByText('webSearch.picker.title')).toBeTruthy();
  });

  it('webSearchOptExternal: manually turning external off → only the external of this model is turned off, session web search is not written', async () => {
    const data = await import('./webSearch-shots-data');
    const { ModelOptionsPopover } = await import('../../../components/chat/ModelOptionsPopover');
    const shot = data.webSearchShotPlan('webSearchOptExternal' as never, loadManifest()).modelOptions!;
    const onWebPreferenceChange = vi.fn();
    render(
      <ModelOptionsPopover
        provider={shot.provider} model={shot.model} webControl={shot.webControl} webPreference={shot.webPreference}
        onWebPreferenceChange={onWebPreferenceChange} transportIdentity="shots" externalSearchSource={shot.externalSearchSource}
        onOpenSearchServiceSheet={() => {}} onClose={() => {}}
      />,
    );
    const toggle = screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement;
    expect(toggle.checked).toBe(true);
    fireEvent.click(toggle);
    expect((screen.getByRole('switch', { name: /capabilityControlWebSearch/ }) as HTMLInputElement).checked).toBe(false);
    expect(onWebPreferenceChange).not.toHaveBeenCalled();
  });

  it('webSearchSourcePicker: last row "Add search service" carries arm (after success, sends pick_service for the new service)', async () => {
    const data = await import('./webSearch-shots-data');
    const { ModelOptionsPopover } = await import('../../../components/chat/ModelOptionsPopover');
    const shot = data.webSearchShotPlan('webSearchSourcePicker' as never, loadManifest()).modelOptions!;
    const onOpenSearchServiceSheet = vi.fn();
    render(
      <ModelOptionsPopover
        provider={shot.provider} model={shot.model} webControl={shot.webControl} webPreference={shot.webPreference}
        transportIdentity="shots" externalSearchSource={shot.externalSearchSource} initialPane="searchSource"
        onOpenSearchServiceSheet={onOpenSearchServiceSheet} onClose={() => {}}
      />,
    );
    const rows = screen.getByTestId('search-source-picker').querySelectorAll('button');
    fireEvent.click(rows[rows.length - 1]);
    expect(onOpenSearchServiceSheet).toHaveBeenCalledWith({
      initial: { step: 'pick' },
      arm: { modelKey: 'c-openai:GPT-5.6', knownServiceIds: ['s-deepseek', 's-tavily', 's-custom'] },
    });
  });

  it('webSearchOptReuse: one-tap enable primary action', async () => {
    await renderShot('webSearchOptReuse');
    expect(screen.getByText('undefined.webSearch.card.reuseStatus:DeepSeek')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'undefined.webSearch.card.oneTap' })).toBeTruthy();
  });

  it('webSearchSourcePicker: built-in of the model selected, service rows, add row and footer', async () => {
    await renderShot('webSearchSourcePicker');
    const picker = screen.getByTestId('search-source-picker');
    const rows = picker.querySelectorAll('button');
    // Each row: logo + name + subtitle (below the name) + selected checkmark
    expect(rows[0].getAttribute('data-search-source')).toBe('native');
    expect(rows[0].querySelector('[data-provider-logo], [data-search-logo]')).toBeTruthy();
    expect(rows[0].textContent).toContain('webSearch.picker.native');
    expect(rows[0].textContent).toContain('webSearch.picker.nativeSub');
    expect(rows[0].getAttribute('aria-pressed')).toBe('true');
    expect(rows[1].textContent).toContain('DeepSeek');
    expect(rows[1].textContent).toContain('webSearch.picker.defaultSub');
    expect(rows[rows.length - 1].textContent).toContain('webSearch.main.add');
    expect(screen.getByText('webSearch.picker.footer')).toBeTruthy();
  });
});
