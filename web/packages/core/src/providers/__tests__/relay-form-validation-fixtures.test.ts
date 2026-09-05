/**
 * Consistency test for the custom LLM form definition and validation.
 *
 * The rules live in a shared fixture, and each client implements the same pure functions against it so
 * outputs match case by case. `form.fields` locks the layout (order, grouping, English label source
 * strings, placeholders, and whether an edit invalidates the current probe); `cases` locks the
 * four-state credential matrix crossed with {create, edit}.
 *
 * The English label values are asserted in `apps/app/app/providers/relay-form-labels.test.ts` (en.json
 * lives in the app workspace and core does not depend on it in reverse). This file asserts the
 * definition's order, grouping, placeholders, revalidation triggers and whether a label key is present.
 *
 * To change a rule, change the fixture first, then the implementations.
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  RELAY_FORM_FIELDS,
  displayableRelayFormIssues,
  relayFormNormalizedEndpoint,
  validateRelayForm,
  type RelayFormDraft,
  type RelayFormField,
  type RelayFormMode,
} from '../relay-form-validation';

// __tests__ -> providers -> src -> core -> packages -> <repo root>
const FIXTURE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../../../shared/test-fixtures/relay/form-validation.v1.json',
);

interface FixtureFieldDefinition {
  field: string;
  group: string;
  labelEN: string | null;
  placeholder: string | null;
  revalidation: string;
}

interface FixtureCase {
  caseId: string;
  matrixState?: string;
  mode: RelayFormMode;
  draft: {
    endpoint: string;
    apiKey: string;
    authMode: string;
    securityMode: string;
    transport: string;
    modelId?: string;
    modelID?: string;
    headers: { key: string; value: string }[];
    queryParams: { key: string; value: string }[];
    hasSavedCredential: boolean;
  };
  expect: { valid: boolean; issues: { field: string; code: string; detail?: string }[] };
}

interface Fixture {
  version: number;
  form: { fields: FixtureFieldDefinition[] };
  credentialMatrix: { state: string }[];
  cases: FixtureCase[];
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf-8')) as Fixture;

function toDraft(raw: FixtureCase['draft']): RelayFormDraft {
  return {
    endpoint: raw.endpoint,
    apiKey: raw.apiKey,
    authMode: raw.authMode as RelayFormDraft['authMode'],
    securityMode: raw.securityMode as RelayFormDraft['securityMode'],
    transport: raw.transport as RelayFormDraft['transport'],
    modelID: raw.modelID ?? raw.modelId ?? '',
    headers: raw.headers,
    queryParams: raw.queryParams,
    hasSavedCredential: raw.hasSavedCredential,
  };
}

describe('relay form definition (shared with iOS / Android)', () => {
  it('matches the fixture version this implementation was written against', () => {
    expect(fixture.version).toBe(1);
  });

  it('renders fields in the fixture order with the same groups', () => {
    expect(RELAY_FORM_FIELDS.map((definition) => definition.field))
      .toEqual(fixture.form.fields.map((field) => field.field));
    expect(RELAY_FORM_FIELDS.map((definition) => definition.group))
      .toEqual(fixture.form.fields.map((field) => field.group));
  });

  it('keeps placeholders and revalidation triggers identical to the fixture', () => {
    expect(RELAY_FORM_FIELDS.map((definition) => definition.placeholder))
      .toEqual(fixture.form.fields.map((field) => field.placeholder));
    expect(RELAY_FORM_FIELDS.map((definition) => definition.revalidation))
      .toEqual(fixture.form.fields.map((field) => field.revalidation));
  });

  it('declares a label key exactly for the fields the fixture gives an English label', () => {
    // securityMode is a permanent read-only summary row on both the create and detail pages, and the
    // fixture locks its English label.
    expect(RELAY_FORM_FIELDS.map((definition) => definition.labelKey !== null))
      .toEqual(fixture.form.fields.map((field) => field.labelEN !== null));
  });
});

describe('validateRelayForm (shared with iOS / Android)', () => {
  it('covers every credential matrix state in both modes', () => {
    const covered = new Set(
      fixture.cases
        .filter((testCase) => testCase.matrixState)
        .map((testCase) => `${testCase.matrixState}:${testCase.mode}`),
    );
    for (const { state } of fixture.credentialMatrix) {
      expect(covered.has(`${state}:create`), `${state}:create`).toBe(true);
      expect(covered.has(`${state}:edit`), `${state}:edit`).toBe(true);
    }
  });

  for (const testCase of fixture.cases) {
    it(`${testCase.caseId}`, () => {
      const issues = validateRelayForm(toDraft(testCase.draft), testCase.mode);
      expect(issues.length === 0).toBe(testCase.expect.valid);
      expect(issues.map(({ field, code, detail }) => (
        detail === undefined ? { field, code } : { field, code, detail }
      ))).toEqual(testCase.expect.issues);
    });
  }

  it('only exposes a normalized endpoint when the whole form is valid', () => {
    // The assertion input comes straight from the production pure function (validateRelayForm) rather
    // than a hand-built issue list.
    const rejected = fixture.cases.find((item) => !item.expect.valid);
    expect(rejected).toBeDefined();
    expect(relayFormNormalizedEndpoint(toDraft(rejected!.draft), rejected!.mode)).toBeNull();

    const accepted = fixture.cases.find(
      (item) => item.expect.valid && item.draft.endpoint.trim().length > 0,
    );
    expect(accepted).toBeDefined();
    expect(relayFormNormalizedEndpoint(toDraft(accepted!.draft), accepted!.mode)).not.toBeNull();
  });

  it('keeps "required" issues silent and every other issue speakable', () => {
    const speakableFields = new Set<RelayFormField>();
    for (const testCase of fixture.cases) {
      const issues = validateRelayForm(toDraft(testCase.draft), testCase.mode);
      for (const issue of displayableRelayFormIssues(issues)) speakableFields.add(issue.field);
      // "Required field" issues are not in the displayable set: red text on an empty form at first paint is noise.
      expect(displayableRelayFormIssues(issues).map((issue) => issue.code))
        .not.toContain('endpoint_required');
      expect(displayableRelayFormIssues(issues).map((issue) => issue.code))
        .not.toContain('credential_required');
    }
    expect(speakableFields.size).toBeGreaterThan(0);
  });

  it('returns issues in the golden field order', () => {
    const order = RELAY_FORM_FIELDS.map((definition) => definition.field);
    const issues = validateRelayForm(
      {
        endpoint: 'https://relay.example.com/v1',
        apiKey: 'sk-relay-0123\u30000456789abcdef',
        authMode: 'bearer',
        securityMode: 'local_http',
        transport: 'openai_chat_completions',
        modelID: '',
        headers: [],
        queryParams: [],
        hasSavedCredential: false,
      },
      'create',
    );
    // The scheme mismatch (security_mode) has to be reported before the key character set
    // (api_key), and both have to be reported.
    expect(issues.map((issue) => issue.code))
      .toEqual(['security_mode_scheme_mismatch', 'credential_invalid_characters']);
    const indexes = issues.map((issue) => order.indexOf(issue.field));
    expect(indexes).toEqual([...indexes].sort((a, b) => a - b));
  });
});
