import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import React from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import type { OfficialEndpointConfig } from '@oriveo/core/providers/transport/endpoint-resolver';
import { createAppStore } from '../../../lib/core/store/app-store';
import { updateProviderOfficialEndpoint } from '../../../lib/core/provider-ops';
import { BaseURLEditor } from './components/BaseURLEditor';

/**
 * Setup fields for official detail page address editing: template regions are selectable, selecting one shows the Workspace ID slot,
 * saving is unavailable for an invalid value; one save writes the address, region source and setupValues. Fixture setup-fields.v1.json.
 */

vi.mock('../../../lib/infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

// The translation function must be stable (creating a new one each time makes components depending on it re-render repeatedly).
const translate = (key: string) => key;
vi.mock('next-intl', () => ({ useTranslations: () => translate }));
vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick, disabled }: { children: React.ReactNode; onClick?: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onClick} disabled={disabled}>{children}</button>
  ),
  EditIcon: () => null,
}));

interface FormCase {
  caseId: string;
  regionId: string;
  expectFields: string[];
  value: string | null;
  expectSubmit: boolean;
  configPatch?: Record<string, unknown>;
  expect?: { endpointSource: string; baseURLText: string; setupValues?: Record<string, string> };
}
interface Fixture {
  config: Omit<OfficialEndpointConfig, 'regionOptions'> & { kind: string; regionOptions: Array<{ id: string; label: string; baseURL: string }> };
  decodeCases: Array<{ caseId: string; expectRegionIds?: string[] }>;
  formCases: FormCase[];
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'provider-catalog', 'setup-fields.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('setup-fields.v1.json not found');
})();

// Regions left after decoding (unknown placeholders / untrusted templates were already dropped at decode time).
const keptIDs = fixture.decodeCases.find((item) => item.caseId === 'keeps_trusted_template_option')!.expectRegionIds!;
const options = fixture.config.regionOptions.filter((option) => keptIDs.includes(option.id));
const config: OfficialEndpointConfig = { ...fixture.config, regionOptions: options };
const PLAIN = options.find((option) => !option.baseURL.includes('{'))!;
const TEMPLATE = options.find((option) => option.baseURL.includes('{'))!;

function renderEditor(props: Partial<React.ComponentProps<typeof BaseURLEditor>> = {}) {
  const onSave = vi.fn();
  const onSaveEndpoint = vi.fn();
  render(
    <BaseURLEditor
      currentURL={PLAIN.baseURL}
      endpointOptions={options}
      setupConfig={{ kind: fixture.config.kind, config }}
      onSave={onSave}
      onSaveEndpoint={onSaveEndpoint}
      {...props}
    />,
  );
  fireEvent.click(screen.getByRole('button', { name: 'editBaseURL' }));
  return { onSave, onSaveEndpoint };
}

const saveButton = () => screen.getByRole('button', { name: 'saveBaseURL' }) as HTMLButtonElement;

afterEach(cleanup);

describe('SETUP-FIELDS-DETAIL-01 official detail page template items selectable + Workspace ID validation', () => {
  it('SETUP-FIELDS-DETAIL-01 template regions are listed; ordinary regions show no slot and save through the original address', () => {
    const { onSave, onSaveEndpoint } = renderEditor();

    expect(screen.getByRole('button', { name: new RegExp(TEMPLATE.label) })).toBeTruthy();
    expect(screen.queryByLabelText('workspaceId')).toBeNull();
    fireEvent.click(saveButton());
    expect(onSave).toHaveBeenCalledWith(PLAIN.baseURL);
    expect(onSaveEndpoint).not.toHaveBeenCalled();
  });

  const templateCases = fixture.formCases.filter((item) => item.regionId === TEMPLATE.id && !item.configPatch);
  it.each(templateCases.map((item) => [item.caseId, item] as const))('SETUP-FIELDS-DETAIL-01 %s', (_caseId, item) => {
    renderEditor();
    fireEvent.click(screen.getByRole('button', { name: new RegExp(TEMPLATE.label) }));

    expect(item.expectFields).toEqual(['workspaceId']);
    const input = screen.getByLabelText('workspaceId') as HTMLInputElement;
    if (item.value !== null) fireEvent.change(input, { target: { value: item.value } });
    expect(saveButton().disabled).toBe(!item.expectSubmit);
  });
});

describe('SETUP-FIELDS-DETAIL-02 save writes setupValues and region source', () => {
  const valid = fixture.formCases.find((item) => item.caseId === 'valid_value_builds_base')!;

  function qwenProvider(overrides: Partial<Provider> = {}): Provider {
    return {
      id: 'qwen-1',
      kind: 'qwen',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: 'sk-qwen',
      apiKeyPreview: 'sk-...qwen',
      baseURLText: PLAIN.baseURL,
      endpointSource: `region:${PLAIN.id}`,
      ...overrides,
    };
  }

  it('SETUP-FIELDS-DETAIL-02 one write of address, region source and setupValues', () => {
    const store = createAppStore();
    const provider = qwenProvider();
    store.getState().addProvider(provider);
    const { onSave } = renderEditor({
      onSaveEndpoint: (endpoint) => updateProviderOfficialEndpoint(store, provider, endpoint),
    });

    fireEvent.click(screen.getByRole('button', { name: new RegExp(TEMPLATE.label) }));
    fireEvent.change(screen.getByLabelText('workspaceId'), { target: { value: valid.value } });
    fireEvent.click(saveButton());

    expect(onSave).not.toHaveBeenCalled();
    const saved = store.getState().providers.find((item) => item.id === provider.id)!;
    expect(saved.baseURLText).toBe(valid.expect!.baseURLText);
    expect(saved.endpointSource).toBe(valid.expect!.endpointSource);
    expect(saved.setupValues).toEqual(valid.expect!.setupValues);
  });

  it('SETUP-FIELDS-DETAIL-02 opening the editor prefills from the stored setupValues, and the stored template region is selected', () => {
    renderEditor({
      currentURL: valid.expect!.baseURLText,
      storedEndpointSource: valid.expect!.endpointSource,
      storedSetupValues: valid.expect!.setupValues,
    });

    expect(screen.getByRole('button', { name: new RegExp(TEMPLATE.label) }).getAttribute('aria-pressed')).toBe('true');
    expect((screen.getByLabelText('workspaceId') as HTMLInputElement).value).toBe('ws-123abc');
    expect(saveButton().disabled).toBe(false);
  });
});
