/**
 * Cross-client label assertions for the relay form.
 *
 * The one label representation every client can assert on is the English source string, so each
 * client checks that its resolved English value equals `labelEN` in the shared relay form
 * validation fixture.
 *
 * The second assertion keeps the two flows from drifting apart: the create page and the edit page
 * each have their own next-intl namespace, so one field has two keys. They must resolve to the
 * same English string, or the same field ends up with two different names in the two flows.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  RELAY_FORM_FIELDS,
  type RelayFormField,
} from '@oriveo/core/providers/relay-form-validation';
import { RELAY_FORM_ISSUE_MESSAGE_KEYS } from '../../lib/core/providers/relay-form-messages';

// vitest starts with cwd = apps/app, so four levels up is the repository root.
const FIXTURE_PATH = resolve(
  process.cwd(),
  '../../..',
  'shared/test-fixtures/relay/form-validation.v1.json',
);

interface Fixture {
  form: { fields: { field: string; labelEN: string | null }[] };
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf-8')) as Fixture;
const messages = JSON.parse(
  readFileSync(resolve(process.cwd(), 'messages/en.json'), 'utf-8'),
) as Record<string, unknown>;

function resolveMessage(key: string): string | undefined {
  const value = key.split('.').reduce<unknown>(
    (node, segment) => (node && typeof node === 'object'
      ? (node as Record<string, unknown>)[segment]
      : undefined),
    messages,
  );
  return typeof value === 'string' ? value : undefined;
}

/** Keys each flow actually renders with (create page = relaySetup, edit page = relayDetail and providerDetail). */
const FLOW_LABEL_KEYS: Partial<Record<RelayFormField, string[]>> = {
  endpoint: ['pages.relaySetup.requestURLLabel', 'pages.relayDetail.endpoint'],
  api_key: ['pages.relaySetup.apiKeyLabel', 'pages.providerDetail.apiKey'],
  model_id: ['pages.relaySetup.defaultModelLabel'],
  transport: ['pages.relayDetail.transport'],
  auth_mode: ['pages.relayDetail.authMode'],
  headers: ['pages.relayDetail.headers'],
  query_params: ['pages.relayDetail.queryParams'],
  security_mode: ['pages.relayDetail.connectionType'],
};

describe('relay form labels (shared with iOS / Android)', () => {
  it('resolves every declared label key to the fixture English source string', () => {
    const resolved = RELAY_FORM_FIELDS.map((definition) => ({
      field: definition.field,
      labelEN: definition.labelKey === null ? null : resolveMessage(definition.labelKey) ?? null,
    }));
    expect(resolved).toEqual(
      fixture.form.fields.map((field) => ({ field: field.field, labelEN: field.labelEN })),
    );
  });

  it('keeps the create flow and the edit flow on the same English label per field', () => {
    for (const definition of RELAY_FORM_FIELDS) {
      const keys = FLOW_LABEL_KEYS[definition.field];
      if (!keys) {
        // Fields with no UI home stay out honestly; no key is invented for a row that does not exist.
        expect(definition.labelKey).toBeNull();
        continue;
      }
      const values = keys.map((key) => resolveMessage(key));
      expect(values, definition.field).toEqual(values.map(() => resolveMessage(definition.labelKey!)));
    }
  });

  it('gives every issue code a message key that actually exists in en.json', () => {
    const missing = Object.entries(RELAY_FORM_ISSUE_MESSAGE_KEYS)
      .filter(([, key]) => resolveMessage(key) === undefined)
      .map(([code]) => code);
    expect(missing).toEqual([]);
  });

  it('keeps authMode at the one dynamic schema key and removes the three dead static copies', () => {
    expect(RELAY_FORM_FIELDS.find((field) => field.field === 'auth_mode')?.labelKey)
      .toBe('pages.relayDetail.authMode');
    expect(resolveMessage('pages.relayDetail.authMode')).toBe('Authentication');
    expect(resolveMessage('pages.relaySetup.authMode')).toBeUndefined();
    expect(resolveMessage('pages.relaySetup.field.authMode')).toBeUndefined();
    expect(resolveMessage('pages.relaySetup.advanced.authMode')).toBeUndefined();
  });
});
