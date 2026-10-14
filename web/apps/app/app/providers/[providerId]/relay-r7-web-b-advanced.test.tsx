import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider } from '@oriveo/shared';
import { toProviderError } from '@oriveo/core/providers/errors';
import { RELAY_ADVANCED_TEXT, relayModelAdvancedBoard } from './relay-model-advanced-board';
import { RelayModelAdvanced } from './components/RelayModelAdvanced';
import { RelaySettingsFailureCard } from './components/RelaySettingsFailureCard';

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

// Stable reference: giving a new function on every render would make effects that depend on t fire repeatedly.
const intl = vi.hoisted(() => ({
  t: (key: string, values?: Record<string, unknown>) => (values ? `${key}(${JSON.stringify(values)})` : key),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => intl.t,
  useLocale: () => 'en',
}));

const ROOT = process.cwd();
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');
const NOW = Date.parse('2026-10-11T08:00:00.000Z');
const KEY = 'sk-relay-secret-0123456789';

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return { id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '', ...extra };
}

function relayProvider(enabled: AIModel[]): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = 'openai_chat_completions';
  requested.resolvedAPIBaseURL = 'https://api.myrelay.dev/v1';
  return {
    id: 'relay-r7-b',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: enabled,
    catalogModels: [...enabled],
    apiKey: KEY,
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'https://api.myrelay.dev/v1',
    relayResolvedTransport: 'openai_chat_completions',
    relayResolvedAuthMode: 'bearer',
  };
}

function cssRule(source: string, selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(source)?.[1] ?? '';
}

describe('RL2-CAPROW-01 capability-row source badge shows only when the status truly comes from that override', () => {
  it('does not show Tested / You set when the override is not applied to the status (no evidence identity)', () => {
    // Capability evidence identity is off: the existing vision / tools judgments do not read overrides, so status and override disagree.
    const item = model('gpt-5.6-sol', {
      relayCapabilityOverrides: { image: { value: true, source: 'tested' }, toolCall: { value: true, source: 'tested' } },
    });
    const board = relayModelAdvancedBoard({ provider: relayProvider([item]), model: item, now: NOW });
    for (const row of board.capabilityRows.filter((entry) => entry.cap === 'image' || entry.cap === 'toolCall')) {
      const fromOverride = row.state === 'supported';
      expect([row.cap, row.source === 'tested']).toEqual([row.cap, fromOverride]);
    }
  });

  it('shows the source as before when the override does land on the status (file / image generation read overrides)', () => {
    const item = model('m', {
      relayCapabilityOverrides: { file: { value: true, source: 'user' }, imageGeneration: { value: false, source: 'tested' } },
    });
    const board = relayModelAdvancedBoard({ provider: relayProvider([item]), model: item, now: NOW });
    const rows = Object.fromEntries(board.capabilityRows.map((row) => [row.cap, [row.state, row.source]]));
    expect(rows.file).toEqual(['supported', 'user']);
    expect(rows.imageGeneration).toEqual(['unsupported', 'tested']);
  });
});

describe('C5 Advanced page: test capabilities at the bottom of the capability card; restore all is a text link', () => {
  function renderAdvanced(restoreEnabled: boolean) {
    const item = model('m');
    const board = relayModelAdvancedBoard({ provider: relayProvider([item]), model: item, now: NOW });
    return render(
      <RelayModelAdvanced
        board={{ ...board, testEntry: true, restoreAllEnabled: restoreEnabled }}
        backLabel="back"
        onBack={() => undefined}
        onRestoreAll={() => undefined}
        onSelectSegment={() => undefined}
        onSetControl={() => undefined}
        onToggleLevel={() => undefined}
        onTestCapabilities={() => undefined}
        onSelectKey={() => undefined}
      />,
    );
  }

  it('Test capabilities sits inside the capability card, after the capability rows', () => {
    renderAdvanced(true);
    const card = document.querySelector('[data-advanced-section="capabilities"] [data-advanced-cap="image"]')!.parentElement!;
    const action = screen.getByRole('button', { name: 'capabilityTest.action' });
    expect(card.contains(action)).toBe(true);
    expect(card.lastElementChild!.contains(action)).toBe(true);
  });

  it('Restore all to automatic is a text link (accent color textAction, with icon), greyed out when nothing can be restored', () => {
    renderAdvanced(true);
    const restore = screen.getByRole('button', { name: RELAY_ADVANCED_TEXT.restoreAll }) as HTMLButtonElement;
    expect(restore.classList.contains('textAction')).toBe(true);
    expect(restore.querySelector('svg')).not.toBeNull();
    expect(restore.disabled).toBe(false);
  });

  it('Restore all is disabled when nothing can be restored', () => {
    renderAdvanced(false);
    expect((screen.getByRole('button', { name: RELAY_ADVANCED_TEXT.restoreAll }) as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('Edit Connection verification failure card', () => {
  const upstream = '{"error":{"message":"Invalid API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}';
  // Production path: what pingRelay throws on a 401 is the product of toProviderError.
  const error = toProviderError(401, upstream, 'https://api.myrelay.dev/v1/chat/completions', undefined, [KEY]);

  function renderCard() {
    render(
      <RelaySettingsFailureCard
        error={error}
        canSaveUnverified
        apiKey={KEY}
        connectionKeySecrets={[KEY]}
        relayRequested={relayProvider([]).relayRequested!}
        showRetry={false}
        onRetry={() => undefined}
        onSaveUnverified={() => undefined}
        onDismiss={() => undefined}
      />,
    );
    return screen.getByRole('alert');
  }

  it('title = error kind title, body = localized guidance, upstream original text only goes into technical details', () => {
    expect(error.kind).toBe('invalidKey');
    const card = renderCard();
    expect(card.querySelector('strong')!.textContent).toBe('invalidKey.title');
    expect(card.firstElementChild!.textContent).toContain('invalidKey.message');
    expect(card.firstElementChild!.textContent).not.toContain('Invalid API key provided');
    const details = card.querySelector('details')!;
    expect(details.open).toBe(false);
    expect(details.textContent).toContain('Invalid API key provided');
  });

  it('warning tone; when saving unverified is allowed the primary button = Save anyway (unverified)', () => {
    const card = renderCard();
    expect(card.getAttribute('data-tone')).toBe('warning');
    expect(screen.getByRole('button', { name: 'saveUnverified' })).toBeTruthy();
    const css = read('app/providers/[providerId]/ProviderDetail.module.css');
    expect(cssRule(css, '.relayVerificationFailure')).toContain('--o-warning');
    expect(cssRule(css, '.relayFailureIcon')).toContain('--o-warning');
  });
});
