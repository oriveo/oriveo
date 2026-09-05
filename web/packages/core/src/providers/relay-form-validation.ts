/**
 * Declarative field definitions plus pure validation for the custom LLM (relay) form.
 *
 * Why this file exists: the create page (`RelaySetup.tsx`) and the edit page (`RelayDetail.tsx` /
 * `RelayConnectionCard`) each carried their own answer to "can this be saved", and the same rule
 * drifted three ways: edit required a non-empty key regardless of authMode, create required one too,
 * and edit always measured the address against the default `remote_https` mode, so a local engine
 * `http://` address was permanently invalid and even renaming it could not be saved.
 *
 * There is exactly one place per rule: endpoint validity is delegated to `classifyRelayEndpoint` (the
 * same classifier the send boundary uses) and credential requirements to
 * `relayCredentialInputRequired`. This file only owns the form-level field layout and combination
 * rules; it reimplements none of the underlying checks.
 *
 * Not done here: merging the create and edit pages into one component. Their state machines differ
 * fundamentally (create has probe-generation guards, one-token verification and an empty-catalog exit;
 * edit has credential reuse and catalog invalidation), and merging would just smear the two together.
 */
import type { RelayAuthMode, RelayKeyValue, RelayTransport } from '@oriveo/shared/pure-types';
import {
  classifyRelayEndpoint,
  isSensitiveRelayName,
  type RelayConnectionSecurityMode,
} from '@oriveo/shared/relay/endpoint-policy';
import { isPrintableAsciiKey } from './key-validation';
import { relayCredentialInputRequired, relayRequiresCredential } from './relay-runtime-support';

/* ── Field layout (declarative definitions) ───────────── */

/**
 * Form fields, one per field of `RelayFormDraft`.
 *
 * The display name is not among them: in the create flow it is an optional display label and in the
 * edit flow it goes through a separate rename entry point, so it takes part in no validation.
 */
export type RelayFormField =
  | 'endpoint'
  | 'security_mode'
  | 'api_key'
  | 'model_id'
  | 'transport'
  | 'auth_mode'
  | 'headers'
  | 'query_params';

/** Field groups. The order is the order the groups appear in the form. */
export type RelayFormGroup = 'connection' | 'protocol' | 'advanced_http';

/** Whether editing this field invalidates the current probe/verification generation. */
export type RelayFormRevalidation =
  | 'always'
  | 'never'
  /**
   * Default model only: switching to another entry within an already discovered catalog does not
   * invalidate the probe (the protocol was verified against that same catalog, and clearing the result
   * would make the catalog picker itself disappear). Typing an ID from outside the catalog does mean the
   * user changed target.
   */
  | 'unless_within_discovered_catalog';

export interface RelayFormFieldDefinition {
  readonly field: RelayFormField;
  readonly group: RelayFormGroup;
  /** Full next-intl key for the label. The connection mode is a read-only summary row on both pages. */
  readonly labelKey: string | null;
  /**
   * Placeholder. Address, key and KV are non-localized example literals; the default model
   * placeholder is dynamic (the flagship model ID published in metadata) and is therefore `null`.
   */
  readonly placeholder: string | null;
  readonly revalidation: RelayFormRevalidation;
}

/**
 * Golden layout order: the array order is the top-to-bottom render order, used by both the create and
 * edit pages. `security_mode` comes after the address, so the address is described first and how to
 * reach it second.
 */
export const RELAY_FORM_FIELDS: readonly RelayFormFieldDefinition[] = [
  {
    field: 'endpoint',
    group: 'connection',
    labelKey: 'pages.relayDetail.endpoint',
    placeholder: 'https://api.example.com/v1',
    revalidation: 'always',
  },
  {
    field: 'security_mode',
    group: 'connection',
    labelKey: 'pages.relayDetail.connectionType',
    placeholder: null,
    revalidation: 'always',
  },
  {
    field: 'api_key',
    group: 'connection',
    labelKey: 'pages.providerDetail.apiKey',
    placeholder: 'sk-...',
    revalidation: 'always',
  },
  {
    field: 'model_id',
    group: 'connection',
    labelKey: 'pages.relaySetup.defaultModelLabel',
    placeholder: null,
    revalidation: 'unless_within_discovered_catalog',
  },
  {
    field: 'transport',
    group: 'protocol',
    labelKey: 'pages.relayDetail.transport',
    placeholder: null,
    revalidation: 'always',
  },
  {
    field: 'auth_mode',
    group: 'protocol',
    labelKey: 'pages.relayDetail.authMode',
    placeholder: null,
    revalidation: 'always',
  },
  {
    field: 'headers',
    group: 'advanced_http',
    labelKey: 'pages.relayDetail.headers',
    placeholder: 'X-Internal-Token',
    revalidation: 'always',
  },
  {
    field: 'query_params',
    group: 'advanced_http',
    labelKey: 'pages.relayDetail.queryParams',
    placeholder: 'tenant',
    revalidation: 'always',
  },
];

export function relayFormFieldDefinition(
  field: RelayFormField,
): RelayFormFieldDefinition | undefined {
  return RELAY_FORM_FIELDS.find((definition) => definition.field === field);
}

/* ── Validation results ───────────────────────────────── */

export type RelayFormIssueCode =
  /** The address is empty. */
  | 'endpoint_required'
  /** The address was rejected by the address policy; `detail` holds its reason slug. */
  | 'endpoint_rejected'
  /** Credential material (key, sensitive header or sensitive query) sent over a cleartext transport. */
  | 'cleartext_credentials'
  /** Connection mode and address scheme are incompatible. The mode is never auto-adjusted to fit the address. */
  | 'security_mode_scheme_mismatch'
  /** This connection needs a key and the form has none yet. */
  | 'credential_required'
  /** The key contains non-printable ASCII, most often full-width or zero-width spaces pasted along with it. */
  | 'credential_invalid_characters';

export interface RelayFormIssue {
  readonly field: RelayFormField;
  readonly code: RelayFormIssueCode;
  /** Machine-readable detail (for a rejected endpoint, the address policy's reason slug). Not shown in the UI. */
  readonly detail?: string;
}

/**
 * "Required field" issues only keep the primary button disabled: an empty field is its own hint, and
 * red text on first paint is noise. Everything else means the user filled something in incorrectly and
 * needs a plain-language message right away, otherwise the button stays grey with no explanation.
 */
export function isSilentRelayFormRequirement(code: RelayFormIssueCode): boolean {
  return code === 'endpoint_required' || code === 'credential_required';
}

/** The issues that warrant an immediate plain-language message. */
export function displayableRelayFormIssues(
  issues: readonly RelayFormIssue[],
): RelayFormIssue[] {
  return issues.filter((issue) => !isSilentRelayFormRequirement(issue.code));
}

/* ── Draft state and validation ───────────────────────── */

export type RelayFormMode = 'create' | 'edit';

/** Form draft. The create and edit pages keep their own state machines but both reduce state into this draft for validation. */
export interface RelayFormDraft {
  endpoint: string;
  apiKey: string;
  authMode: RelayAuthMode;
  securityMode: RelayConnectionSecurityMode;
  transport: RelayTransport;
  modelID: string;
  headers: readonly RelayKeyValue[];
  queryParams: readonly RelayKeyValue[];
  /** A non-empty key is already in the keystore. Always `false` in `create`, which has no keystore. */
  hasSavedCredential: boolean;
}

const FIELD_ORDER: readonly RelayFormField[] = RELAY_FORM_FIELDS.map((item) => item.field);

/**
 * Pure form validation. No side effects, no network requests, no global state reads.
 *
 * The returned order always matches the layout order of `RELAY_FORM_FIELDS`, and one field can return
 * several issues (address first, then credentials).
 */
export function validateRelayForm(
  draft: RelayFormDraft,
  mode: RelayFormMode,
): RelayFormIssue[] {
  const issues: RelayFormIssue[] = [];
  const trimmedEndpoint = draft.endpoint.trim();
  const trimmedKey = draft.apiKey.trim();
  // In `edit` the keystore already holds a key: leaving the input empty means "unchanged", not "clear".
  // In `create` there is no keystore, only the key the user just typed.
  const hasCredential = trimmedKey.length > 0 || (mode === 'edit' && draft.hasSavedCredential);

  // 1. Address
  if (trimmedEndpoint.length === 0) {
    issues.push({ field: 'endpoint', code: 'endpoint_required' });
  } else {
    if (hasSchemeModeMismatch(trimmedEndpoint, draft.securityMode)) {
      issues.push({ field: 'security_mode', code: 'security_mode_scheme_mismatch' });
    }
    // The same classifier the send boundary uses, so form validation and saving cannot disagree.
    const classification = classifyRelayEndpoint({
      raw: trimmedEndpoint,
      securityMode: draft.securityMode,
      credentials: {
        authMode: draft.authMode,
        hasKey: hasCredential,
        sensitiveHeaders: sensitiveNames(draft.headers),
        sensitiveQueryKeys: sensitiveNames(draft.queryParams),
      },
    });
    if (!classification.allowed) {
      if (classification.reason === 'cleartext_credentials') {
        issues.push({
          field: cleartextOffendingField(draft, hasCredential),
          code: 'cleartext_credentials',
          detail: classification.reason,
        });
      } else {
        issues.push({
          field: 'endpoint',
          code: 'endpoint_rejected',
          detail: classification.reason,
        });
      }
    }
  }

  // 2. Credential requirement (the single rule lives in the credential state machine; no thresholds are copied here)
  if (relayCredentialInputRequired(mode, draft.authMode, hasCredential)) {
    issues.push({ field: 'api_key', code: 'credential_required' });
  }

  // 3. Key character set. An empty string is valid for `auth=none` and for leaving the field blank while
  //    editing, so only non-empty keys are checked.
  if (trimmedKey.length > 0 && !isPrintableAsciiKey(trimmedKey)) {
    issues.push({ field: 'api_key', code: 'credential_invalid_characters' });
  }

  return issues
    .map((issue, index) => ({ issue, index }))
    .sort((lhs, rhs) => {
      const delta = fieldIndex(lhs.issue.field) - fieldIndex(rhs.issue.field);
      return delta !== 0 ? delta : lhs.index - rhs.index;
    })
    .map((entry) => entry.issue);
}

/** Normalized address once validation passes, `null` otherwise. Both paths share one check rather than recomputing. */
export function relayFormNormalizedEndpoint(
  draft: RelayFormDraft,
  mode: RelayFormMode,
): string | null {
  if (validateRelayForm(draft, mode).length > 0) return null;
  const hasCredential = draft.apiKey.trim().length > 0
    || (mode === 'edit' && draft.hasSavedCredential);
  const classification = classifyRelayEndpoint({
    raw: draft.endpoint.trim(),
    securityMode: draft.securityMode,
    credentials: {
      authMode: draft.authMode,
      hasKey: hasCredential,
      sensitiveHeaders: sensitiveNames(draft.headers),
      sensitiveQueryKeys: sensitiveNames(draft.queryParams),
    },
  });
  return classification.allowed ? classification.normalized ?? null : null;
}

/* ── Internal checks ──────────────────────────────────── */

function fieldIndex(field: RelayFormField): number {
  const index = FIELD_ORDER.indexOf(field);
  return index < 0 ? FIELD_ORDER.length : index;
}

function sensitiveNames(pairs: readonly RelayKeyValue[]): string[] {
  return pairs.filter((pair) => isSensitiveRelayName(pair.key)).map((pair) => pair.key);
}

/**
 * Consistency between the connection mode and the address scheme, checked at form level rather than
 * only on submit.
 *
 * Only addresses where the user wrote a scheme explicitly are checked: without one the address policy
 * fills in a scheme matching the current mode, which is always compatible. The case of an explicit
 * `http://` under a mode that requires encryption is reported by the address policy as
 * `cleartext_not_allowed`; this covers only the half it cannot see, an encrypted address under a mode
 * that declares cleartext.
 */
function hasSchemeModeMismatch(
  endpoint: string,
  securityMode: RelayConnectionSecurityMode,
): boolean {
  if (securityMode !== 'local_http' && securityMode !== 'private_vpn') return false;
  return endpoint.toLowerCase().startsWith('https://');
}

/** Which piece of credential material crossed the cleartext boundary. Attributed in layout order, so the user gets something to click. */
function cleartextOffendingField(
  draft: RelayFormDraft,
  hasCredential: boolean,
): RelayFormField {
  if (relayRequiresCredential(draft.authMode) || hasCredential) return 'api_key';
  if (draft.headers.some((pair) => isSensitiveRelayName(pair.key))) return 'headers';
  return 'query_params';
}
