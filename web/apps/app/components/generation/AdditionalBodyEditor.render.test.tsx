/**
 * Additional request body editor: data is written and read entirely through the production store, and the conversation-level record is asserted through the production outbound builder.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) => (
    values ? `${key}:${Object.values(values).join(',')}` : key
  ),
}));

vi.mock('../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../lib/core/metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { additionalBodyScope, loadAdditionalBody, saveAdditionalBody, withAdditionalBody } from '../../lib/core/chat/additional-body-settings';
import { AdditionalBodyEditor } from './AdditionalBodyEditor';

const anthropic = { id: 'conn-a', kind: 'anthropic', models: [], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
const llama = { ...anthropic, id: 'conn-l', kind: 'relay', relayRequested: { engineProfile: 'llamacpp' } } as unknown as Provider;
const model = { id: 'claude-sonnet-4-6', name: 'M', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' } as AIModel;

const SAMPLE = '{\n  "chat_template_kwargs": {\n    "enable_thinking": false\n  },\n  "cache_prompt": true,\n  "messages": []\n}';

const textarea = () => screen.getByRole('textbox') as HTMLTextAreaElement;
const sendSwitch = () => screen.getByRole('switch');

beforeEach(() => localStorage.clear());
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('AdditionalBodyEditor', () => {
  it('written through the production store -> shows content and switch; toggling the switch keeps the content, and content and switch are stored separately', () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"top_k":3}', enabled: true });
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    expect(textarea().value).toBe('{"top_k":3}');
    expect(sendSwitch().getAttribute('aria-checked')).toBe('true');

    fireEvent.click(sendSwitch());
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))).toMatchObject({ raw: '{"top_k":3}', enabled: false });
    expect(textarea().value).toBe('{"top_k":3}');

    fireEvent.change(textarea(), { target: { value: '{"top_k":4}' } });
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))).toMatchObject({ raw: '{"top_k":4}', enabled: false });
  });

  it('the switch defaults to off when there is no record; writing content for the first time does not turn it on', () => {
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    expect(sendSwitch().getAttribute('aria-checked')).toBe('false');
    fireEvent.change(textarea(), { target: { value: '{"top_k":3}' } });
    expect(sendSwitch().getAttribute('aria-checked')).toBe('false');
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))).toMatchObject({ raw: '{"top_k":3}', enabled: false });
    // While it is off, the production outbound path does not send it.
    expect(withAdditionalBody(undefined, { provider: anthropic, model })?.additionalBody).toBeUndefined();
  });

  it('syntax error: the failing line is highlighted and the line number and reason are shown under the editor', () => {
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    fireEvent.change(textarea(), { target: { value: '{\n "a": 1,\n "b": ,\n}' } });
    const errorLines = [...document.querySelectorAll('[data-error-line="true"]')].map((node) => node.textContent);
    expect(errorLines).toEqual(['3']);
    expect(screen.getByTestId('additional-body-error').textContent).toBe('additionalBodyRejected.line:3,additionalBodyRejected.reasonInvalidJson');
    expect(textarea().getAttribute('aria-invalid')).toBe('true');
  });

  it('"when sending" list: each leaf path is marked as added; protected fields are marked as not editable, with the reason and a "delete line N" hint', () => {
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    fireEvent.change(textarea(), { target: { value: SAMPLE } });
    const rows = [...document.querySelectorAll('[data-additional-body-row]')].map((node) => [
      node.getAttribute('data-additional-body-row'), node.getAttribute('data-status'),
    ]);
    expect(rows).toEqual([
      ['chat_template_kwargs.enable_thinking', 'included'],
      ['cache_prompt', 'included'],
      ['messages', 'protected'],
    ]);
    const messagesRow = document.querySelector('[data-additional-body-row="messages"]')!;
    expect(messagesRow.textContent).toContain('additionalBodyCannotChange');
    expect(messagesRow.textContent).toContain('additionalBodyRemoveLine:additionalBodyConversationFilled,6');
    expect(screen.getByTestId('additional-body-error').textContent).toBe('additionalBodyRemoveLine:additionalBodyConversationFilled,6');
    expect([...document.querySelectorAll('[data-error-line="true"]')].map((node) => node.textContent)).toEqual(['6']);
  });

  it('tidy: valid JSON is re-laid out with two-space indentation and saved; invalid JSON shows a hint and is left unchanged', () => {
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    fireEvent.change(textarea(), { target: { value: '{"b":1,"a":{"c":2}}' } });
    fireEvent.click(screen.getByText('additionalBodyTidy'));
    expect(textarea().value).toBe('{\n  "b": 1,\n  "a": {\n    "c": 2\n  }\n}');
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))?.raw).toBe(textarea().value);

    fireEvent.change(textarea(), { target: { value: '{"b":' } });
    fireEvent.click(screen.getByText('additionalBodyTidy'));
    expect(textarea().value).toBe('{"b":');
    expect(screen.getByText('additionalBodyTidyInvalid')).toBeTruthy();
  });

  it('paste: existing content asks for confirmation before being replaced; hidden when the clipboard is unavailable', async () => {
    const readText = vi.fn(async () => '{"top_p":0.5}');
    vi.stubGlobal('navigator', { ...navigator, clipboard: { readText } });
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"top_k":3}', enabled: true });
    const { unmount } = render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    fireEvent.click(screen.getByRole('button', { name: 'additionalBodyPaste' }));
    expect(screen.getByText('additionalBodyPasteReplaceTitle')).toBeTruthy();
    expect(readText).not.toHaveBeenCalled();
    await act(async () => { fireEvent.click(screen.getByTestId('additional-body-paste-confirm')); });
    expect(textarea().value).toBe('{"top_p":0.5}');
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))?.raw).toBe('{"top_p":0.5}');
    unmount();

    vi.stubGlobal('navigator', { ...navigator, clipboard: undefined });
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    expect(screen.queryByRole('button', { name: 'additionalBodyPaste' })).toBeNull();
  });

  it('a local engine connection shows the official docs link and other connections do not', () => {
    const { unmount } = render(<AdditionalBodyEditor provider={llama} model={model} />);
    const link = screen.getByRole('link', { name: 'additionalBodyDocsLink:llama.cpp' }) as HTMLAnchorElement;
    expect(link.href).toMatch(/^https:\/\/github\.com\/ggml-org\/llama\.cpp\//);
    unmount();
    render(<AdditionalBodyEditor provider={anthropic} model={model} />);
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.getByText('additionalBodyFooter')).toBeTruthy();
  });

  it('chat page edits this conversation\'s record: shows the effective record as the base, saves to the conversation layer, and the production builder sends the new content', async () => {
    saveAdditionalBody(additionalBodyScope(anthropic, model), { raw: '{"top_k":3}', enabled: true });
    render(<AdditionalBodyEditor provider={anthropic} model={model} conversationId="c1" />);
    expect(textarea().value).toBe('{"top_k":3}');
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model, 'c1'))).toBeNull();

    fireEvent.change(textarea(), { target: { value: '{"top_k":9}' } });
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model, 'c1'))).toMatchObject({ raw: '{"top_k":9}', enabled: true });
    expect(loadAdditionalBody(additionalBodyScope(anthropic, model))).toMatchObject({ raw: '{"top_k":3}' });

    const options = withAdditionalBody({ supportsWebSearch: false }, { provider: anthropic, model, conversationId: 'c1' });
    expect(options?.additionalBody).toEqual({ raw: '{"top_k":9}' });
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: model.id, baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hi' }], options,
    }, async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata);
    expect(request.body.top_k).toBe(9);
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
