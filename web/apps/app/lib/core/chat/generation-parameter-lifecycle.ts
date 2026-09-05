/**
 * Parameter value lifecycle: **per-field** revalidation after the profile changes.
 *
 * The rule is: after a profile revision or a mode change, revalidate field by field. Compatible
 * values stay in effect, incompatible values are kept as dormant but not sent, and nothing is
 * silently substituted. The earlier failure mode here was **all-or-nothing at record level**: the
 * scope identity carried the whole `profileFingerprint`, so after an endpoint or protocol change
 * the record could not be read back at all. From the user's side that reads as "but I did save
 * this", while the record stays on disk and keeps syncing as an orphan. This module pushes the
 * decision down to a single parameter ID.
 *
 * **The rules match the outbound gate, which is the point of this module**:
 * `applyGenerationParameters` decides whether a value is sent at all using "declared by the
 * profile, non-empty wire value, and support in the outbound allowlist (with relay unknown
 * permitted)". If the read path invented its own rules, the summary would claim 3 values were
 * kept while only 1 is actually sent. So the same rules are mirrored here field by field.
 *
 * **dormant is derived, not stored**: it is what the current profile on this device says about an
 * already stored value. It therefore goes neither into localStorage nor into the
 * `generation_parameter_sync.v1` envelope (see the sync semantics comments).
 */

import type { AIModel, Provider } from '@oriveo/shared';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { resolveGenerationParameterEvidence } from './capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, resolveGenerationProfileForModel } from './stream-options';

/** `active` means it is still sent under the current profile; `dormant` means the value is kept but not sent. The two are mutually exclusive and exhaustive. */
export type GenerationParameterLifecycle = 'active' | 'dormant';

/**
 * Parameter IDs that can reach the final request filter for the current connection and model.
 * Only the evidence support from the same facade is used here; a runtime overlay affects the
 * final requestPolicy but must not move a stored value into dormant. `values` makes an accepted
 * Relay declaration a sendable candidate only when an explicit value already exists.
 */
export function activeGenerationParameterIds(
  provider: Provider,
  model: AIModel,
  values: GenerationParameterOverrides = {},
): Set<string> {
  const profile = resolveGenerationProfileForModel(provider, model);
  const active = new Set<string>();
  const streamOptions = buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, undefined, undefined, values),
    model,
  );
  for (const parameter of profile?.parameters ?? []) {
    if (!parameter.id || !profile?.wire[parameter.id]) continue;
    const override = values[parameter.id];
    const evidence = resolveGenerationParameterEvidence({
      provider,
      model,
      profile,
      parameterId: parameter.id,
      hasExplicitValue: override?.state === 'value',
      streamOptions,
    });
    // Runtime self-heal deliberately changes requestPolicy only. The value
    // stays active/editable so a later cache clear can recover it.
    if (evidence.support === 'supported' || evidence.requestPolicy === 'allow_explicit_unverified') {
      active.add(parameter.id);
    }
  }
  return active;
}

export interface GenerationParameterPartition {
  /** Values still in effect, including empty placeholders such as `inherit` that carry no user intent. */
  active: GenerationParameterOverrides;
  /** Values that are kept but not currently sent. */
  dormant: GenerationParameterOverrides;
  /** Dormant parameter IDs that **actually carry user intent** (`inherit` does not count); the N in the summary line is this length. */
  dormantIds: string[];
}

/**
 * Split one scope record into active and dormant halves under the current profile.
 *
 * When the profile is missing entirely (the connection has not observed any capability yet),
 * everything lands in dormant: "none of these can be sent" is the truth, and a summary line that
 * says "kept, not currently sent" is more honest than pretending nothing was ever saved.
 */
export function partitionGenerationParameterValues(input: {
  provider: Provider;
  model: AIModel;
  values: GenerationParameterOverrides;
}): GenerationParameterPartition {
  const active: GenerationParameterOverrides = {};
  const dormant: GenerationParameterOverrides = {};
  const dormantIds: string[] = [];
  const activeIds = activeGenerationParameterIds(input.provider, input.model, input.values);
  for (const [id, override] of Object.entries(input.values)) {
    if (!override) continue;
    if (activeIds.has(id)) {
      active[id] = override;
      continue;
    }
    // `inherit` carries no user intent (it means "defer to a lower priority"), so it stays on the
    // active side and is not counted; otherwise the summary reports a number the user never set.
    if (override.state === 'inherit') {
      active[id] = override;
      continue;
    }
    dormant[id] = override;
    dormantIds.push(id);
  }
  return { active, dormant, dormantIds };
}
