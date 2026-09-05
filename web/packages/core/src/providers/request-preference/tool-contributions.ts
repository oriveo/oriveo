/**
 * request_preference_contract.v2, typedContributions section.
 *
 * tools/plugins are arrays the builder already owns, so only append_owned is allowed here (the
 * web owner appending its own entries). Replacing or deleting the whole array is not allowed,
 * another owner writing into either target is not allowed, and appending a duplicate identity is
 * not allowed.
 */

import type { OwnerId } from './types';

const TARGETS = new Set(['tools', 'plugins']);
const OPERATIONS = new Set(['append_owned']);
const ALLOWED_OWNER_BY_TARGET: Readonly<Record<string, readonly OwnerId[]>> = {
  tools: ['web'],
  plugins: ['web'],
};

export interface ToolContribution {
  owner: OwnerId;
  target: string;
  operation: string;
  identity: string;
  value: unknown;
}

export type ToolContributionRejectReason =
  | 'unknown_target'
  | 'non_append_operation'
  | 'owner_not_allowed'
  | 'duplicate_identity';

export type ToolContributionResult =
  | { accepted: true; identities: string[]; reason: null }
  | { accepted: false; reason: ToolContributionRejectReason };

export function composeContributions(
  base: readonly string[],
  contributions: readonly ToolContribution[],
): ToolContributionResult {
  const identities = [...base];
  const seen = new Set(base);
  for (const contribution of contributions) {
    if (!TARGETS.has(contribution.target)) return { accepted: false, reason: 'unknown_target' };
    if (!OPERATIONS.has(contribution.operation)) return { accepted: false, reason: 'non_append_operation' };
    const allowedOwners = ALLOWED_OWNER_BY_TARGET[contribution.target] ?? [];
    if (!allowedOwners.includes(contribution.owner)) return { accepted: false, reason: 'owner_not_allowed' };
    if (seen.has(contribution.identity)) return { accepted: false, reason: 'duplicate_identity' };
    seen.add(contribution.identity);
    identities.push(contribution.identity);
  }
  return { accepted: true, identities, reason: null };
}
