/**
 * Maps relay form issues to next-intl copy, so the add and the edit flow state the same
 * conclusion in the same words.
 *
 * The validation rules themselves live in `@oriveo/core/providers/relay-form-validation`; this
 * file only maps a code to a copy key on the web side and decides nothing. Keeping it separate
 * matters because otherwise each flow writes its own error strings, and one rejected address
 * reads as "HTTPS required" on the add page and as something else on the edit page, which looks
 * to the user like two different problems.
 */
import type {
  RelayFormIssue,
  RelayFormIssueCode,
} from '@oriveo/core/providers/relay-form-validation';

/** Full next-intl keys, namespace included; the caller resolves them with the root translator. */
export const RELAY_FORM_ISSUE_MESSAGE_KEYS: Record<RelayFormIssueCode, string> = {
  endpoint_required: 'pages.relaySetup.endpointRequired',
  endpoint_rejected: 'common.relayHttpsRequired',
  cleartext_credentials: 'pages.relayDetail.cleartextCredentialsBlocked',
  security_mode_scheme_mismatch: 'pages.relayDetail.securityModeSchemeMismatch',
  credential_required: 'pages.relaySetup.apiKeyRequired',
  credential_invalid_characters: 'common.apiKeyInvalidChars',
};

export function relayFormIssueMessage(
  issue: RelayFormIssue,
  translate: (key: string) => string,
): string {
  return translate(RELAY_FORM_ISSUE_MESSAGE_KEYS[issue.code]);
}

/** Copy for the first issue on a field, or `undefined` when the field has no issue. */
export function relayFormFieldMessage(
  issues: readonly RelayFormIssue[],
  field: RelayFormIssue['field'],
  translate: (key: string) => string,
): string | undefined {
  const issue = issues.find((item) => item.field === field);
  return issue ? relayFormIssueMessage(issue, translate) : undefined;
}
