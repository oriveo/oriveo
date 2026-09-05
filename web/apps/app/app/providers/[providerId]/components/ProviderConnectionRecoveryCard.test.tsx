// @vitest-environment jsdom
import React from 'react';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { ProviderConnectionRecoveryCard } from './ProviderConnectionRecoveryCard';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

const base: Provider = {
  id: 'official-1',
  kind: 'openAI',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: '',
  apiKeyPreview: '',
};

function renderCard(provider: Provider, localizedLastError?: string) {
  return render(
    <ProviderConnectionRecoveryCard
      provider={provider}
      onEditApiKey={() => {}}
      onRetryConnection={() => {}}
      onDismiss={() => {}}
      localizedLastError={localizedLastError}
    />,
  );
}

describe('ProviderConnectionRecoveryCard', () => {
  // Regression: a subscription chain has no key to fill in, so telling the user to "add an API key"
  // is an instruction they can never follow; the only action that repairs this connection is going
  // through authorization again.
  it('asks a Codex subscription instance with missing credentials to re-authorize rather than add an API key', () => {
    renderCard({ ...base, authMode: 'subscription' });

    expect(screen.getByText('subscriptionNeedsAuthHeadline')).toBeTruthy();
    expect(screen.getByTestId('recovery-reauthorize')).toBeTruthy();
    expect(screen.getByText('reauthorize')).toBeTruthy();
    expect(screen.queryByText('needsKeyHeadline')).toBeNull();
    expect(screen.queryByText('editApiKey')).toBeNull();
  });

  // A real failure on a subscription instance, such as being unable to fetch the catalog, must show
  // the reason. needsKey used to be always true, so this detail branch was unreachable and the user
  // only ever saw "please add an API key".
  it('shows the real error of a Codex subscription instance together with its reason', () => {
    renderCard(
      {
        ...base,
        authMode: 'subscription',
        status: { kind: 'issue', message: 'x' },
        openAISubscription: { accessToken: 'at', accountID: 'acc', obtainedAt: 1 },
      },
      "Couldn't load the model list",
    );

    expect(screen.getByText('subscriptionIssueHeadline')).toBeTruthy();
    expect(screen.getByText("Couldn't load the model list")).toBeTruthy();
    expect(screen.queryByText('connectionIssueHeadline')).toBeNull();
  });

  it('leaves the copy and primary action of a BYOK instance unchanged', () => {
    renderCard(base);

    expect(screen.getByText('needsKeyHeadline')).toBeTruthy();
    expect(screen.getByTestId('recovery-edit-api-key')).toBeTruthy();
    expect(screen.queryByText('subscriptionNeedsAuthHeadline')).toBeNull();
  });
});
