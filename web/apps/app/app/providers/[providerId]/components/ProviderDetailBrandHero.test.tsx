// @vitest-environment jsdom
import React from 'react';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { ProviderDetailBrandHero } from './ProviderDetailBrandHero';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key,
}));

vi.mock('../../../../components/ProviderIcon', () => ({
  ProviderIcon: () => <span data-testid="provider-icon" />,
}));

vi.mock('../../../../lib/core/store/selectors', () => ({
  selectResolvedCatalog: () => ({
    catalog: [],
    enabledModels: [],
    recommendedModels: [],
    defaultModel: null,
    availableModelCount: 2,
    hasManualModels: false,
  }),
}));

const provider: Provider = {
  id: 'official-1',
  kind: 'openAI',
  status: { kind: 'connected' },
  models: [
    {
      id: 'gpt-5.5',
      name: 'gpt-5.5',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: true,
      priceTier: '$5/M',
    },
  ],
  catalogModels: [],
  apiKey: 'sk-test',
  apiKeyPreview: 'sk-test',
  baseURLText: 'https://api.openai.com/v1',
};

const REPO_ROOT = join(process.cwd(), '../../..');
const darkPalettes = JSON.parse(
  readFileSync(join(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json'), 'utf8'),
) as { order: string[]; palettes: Record<string, { primary: string }> };

function luminance(hex: string): number {
  const channels = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const [r, g, b] = channels.map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

describe('ProviderDetailBrandHero', () => {
  afterEach(() => {
    delete document.documentElement.dataset.theme;
    document.documentElement.style.removeProperty('--o-primary');
  });

  it.each(darkPalettes.order)('heroPillLabelMeetsContrast: dark Relay label on #F5F5F5 with palette %s', (id) => {
    const primary = darkPalettes.palettes[id].primary;
    document.documentElement.dataset.theme = 'dark';
    document.documentElement.style.setProperty('--o-primary', primary);

    const { container, unmount } = render(
      <ProviderDetailBrandHero provider={{ ...provider, kind: 'relay', baseURLText: 'https://relay.example.com/v1' }} />,
    );
    const label = (container.querySelector('section') as HTMLElement).style.getPropertyValue('--hero-label-color');

    expect(label).toMatch(/^#[0-9A-F]{6}$/);
    expect(contrastRatio(label, '#F5F5F5')).toBeGreaterThanOrEqual(4.5);
    unmount();
  });

  it('shows the enabled model count instead of the full resolved catalog count', () => {
    render(<ProviderDetailBrandHero provider={provider} />);

    expect(screen.getByText('availableModelsCount({"count":1})')).toBeTruthy();
    expect(screen.queryByText('availableModelsCount({"count":2})')).toBeNull();
  });

  // Regression: the `apiKey` of a subscription instance is always empty, yet this row used to render
  // as a key row, so the user saw "API KEY / tap to configure" - an input they can never fill, and
  // tapping it opens an authorization dialog instead. The label and the value have to change
  // together for the behavior to match.
  it('shows subscription sign-in on the credential row of a Codex subscription instance, not "tap to set an API key"', () => {
    render(
      <ProviderDetailBrandHero
        provider={{
          ...provider,
          apiKey: '',
          apiKeyPreview: '',
          authMode: 'subscription',
          openAISubscription: { accessToken: 'at', accountID: 'acc', obtainedAt: 1 },
        }}
        onEditApiKey={() => {}}
      />,
    );

    expect(screen.getByTestId('hero-subscription-row')).toBeTruthy();
    expect(screen.getByText('signedInWithChatGPT')).toBeTruthy();
    expect(screen.getByText('subscription')).toBeTruthy();
    expect(screen.queryByText('tapToSet')).toBeNull();
    expect(screen.queryByTestId('hero-api-key-row')).toBeNull();
  });

  it('shows the x.ai sign-in state for a Grok subscription instance, with its own wording per path', () => {
    render(
      <ProviderDetailBrandHero
        provider={{
          ...provider,
          kind: 'grok',
          apiKey: '',
          apiKeyPreview: '',
          authMode: 'subscription',
          grokSubscription: { accessToken: 'at', obtainedAt: 1 },
        }}
        onEditApiKey={() => {}}
      />,
    );

    expect(screen.getByText('signedInWithXAI')).toBeTruthy();
    expect(screen.queryByText('signedInWithChatGPT')).toBeNull();
  });

  it('keeps the API key row for a BYOK instance, unaffected by the subscription state', () => {
    render(<ProviderDetailBrandHero provider={provider} onEditApiKey={() => {}} />);

    expect(screen.getByTestId('hero-api-key-row')).toBeTruthy();
    expect(screen.getByText('apiKey')).toBeTruthy();
    expect(screen.queryByText('signedInWithChatGPT')).toBeNull();
  });

  // Availability and the click share one model-selection result; when every model is delisted the selection is null and the button is hidden, instead of staying clickable and jumping to a stale model.
  it('hides start chat when the selection result is null (all delisted) even if the connection still has models', () => {
    render(<ProviderDetailBrandHero provider={provider} onStartChat={() => {}} startChatModelID={null} />);

    expect(screen.queryByText('newChat')).toBeNull();
  });

  it('shows start chat when selection yields a model', () => {
    render(<ProviderDetailBrandHero provider={provider} onStartChat={() => {}} startChatModelID="gpt-5.5" />);

    expect(screen.getByText('newChat')).toBeTruthy();
  });
});
