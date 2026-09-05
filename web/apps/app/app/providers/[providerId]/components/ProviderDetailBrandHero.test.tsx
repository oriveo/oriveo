// @vitest-environment jsdom
import React from 'react';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
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

describe('ProviderDetailBrandHero', () => {
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
});
