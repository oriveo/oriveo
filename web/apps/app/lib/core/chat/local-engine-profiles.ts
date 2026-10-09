import type { GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';

/**
 * Bundled parameter tables for engines that run models locally (reconciled row by row with the shared
 * contract's localEngineProfiles, see `__tests__/local-engine-profiles-contract.test.ts`). A relay's
 * catalog comes from the user's own machine, so the tables are not served remotely and any profile
 * persisted on a connection or model is ignored: every read derives the profile from here.
 *
 * `default` is for display only (the llama.cpp max-token value of -1 shows as "no limit") and is never sent.
 */
export type LocalEngine = 'llamacpp' | 'ollama' | 'lmstudio' | 'vllm';
export type LocalEngineTransport = 'openai_chat_completions' | 'llamacpp_native';

export interface LocalEngineParameterRow {
  id: string;
  wire: string;
  valueSchema: string;
  group: string;
  range?: { min?: number; max?: number; minExclusive?: number };
  default?: number | boolean;
  enumValues?: string[];
}

export const LOCAL_ENGINE_PROFILES: Record<LocalEngine, Partial<Record<LocalEngineTransport, {
  template: string;
  parameters: LocalEngineParameterRow[];
}>>> = {
  llamacpp: {
    openai_chat_completions: {
      template: 'openai_chat_completions',
      parameters: [
        { id: 'max_output_tokens', wire: 'max_tokens', valueSchema: 'integer', group: 'budget', range: { min: 1 }, default: -1 },
        { id: 'stop', wire: 'stop', valueSchema: 'string-list', group: 'budget' },
        { id: 'temperature', wire: 'temperature', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0.8 },
        { id: 'top_p', wire: 'top_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.95 },
        { id: 'top_k', wire: 'top_k', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 40 },
        { id: 'min_p', wire: 'min_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.05 },
        { id: 'typical_p', wire: 'typical_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 1 },
        { id: 'top_n_sigma', wire: 'top_n_sigma', valueSchema: 'number', group: 'sampling', default: -1 },
        { id: 'presence_penalty', wire: 'presence_penalty', valueSchema: 'number', group: 'repetition', default: 0 },
        { id: 'frequency_penalty', wire: 'frequency_penalty', valueSchema: 'number', group: 'repetition', default: 0 },
        { id: 'repeat_penalty', wire: 'repeat_penalty', valueSchema: 'number', group: 'repetition', range: { min: 0 }, default: 1 },
        { id: 'repeat_last_n', wire: 'repeat_last_n', valueSchema: 'integer', group: 'repetition', range: { min: 0 }, default: 64 },
        { id: 'mirostat', wire: 'mirostat', valueSchema: 'integer', group: 'sampling', range: { min: 0, max: 2 }, default: 0 },
        { id: 'mirostat_tau', wire: 'mirostat_tau', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 5 },
        { id: 'mirostat_eta', wire: 'mirostat_eta', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0.1 },
        { id: 'dry_multiplier', wire: 'dry_multiplier', valueSchema: 'number', group: 'repetition', range: { min: 0 }, default: 0 },
        { id: 'dry_base', wire: 'dry_base', valueSchema: 'number', group: 'repetition', range: { min: 1 }, default: 1.75 },
        { id: 'dry_allowed_length', wire: 'dry_allowed_length', valueSchema: 'integer', group: 'repetition', range: { min: 0 }, default: 2 },
        { id: 'dry_penalty_last_n', wire: 'dry_penalty_last_n', valueSchema: 'integer', group: 'repetition', range: { min: -1 }, default: -1 },
        { id: 'dry_sequence_breakers', wire: 'dry_sequence_breakers', valueSchema: 'string-list', group: 'repetition' },
        { id: 'xtc_probability', wire: 'xtc_probability', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0 },
        { id: 'xtc_threshold', wire: 'xtc_threshold', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.1 },
        { id: 'dynatemp_range', wire: 'dynatemp_range', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 'dynatemp_exponent', wire: 'dynatemp_exponent', valueSchema: 'number', group: 'sampling', default: 1 },
        { id: 'samplers', wire: 'samplers', valueSchema: 'string-list', group: 'sampling' },
        { id: 'min_keep', wire: 'min_keep', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 'n_keep', wire: 'n_keep', valueSchema: 'integer', group: 'sampling', range: { min: -1 }, default: 0 },
        { id: 'n_indent', wire: 'n_indent', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 't_max_predict_ms', wire: 't_max_predict_ms', valueSchema: 'integer', group: 'budget', range: { min: 0 }, default: 0 },
        { id: 'ignore_eos', wire: 'ignore_eos', valueSchema: 'boolean', group: 'budget', default: false },
        { id: 'seed', wire: 'seed', valueSchema: 'integer', group: 'reproducibility' },
        { id: 'grammar', wire: 'grammar', valueSchema: 'string', group: 'output_contract' },
        { id: 'json_schema', wire: 'response_format', valueSchema: 'json-schema', group: 'output_contract' },
        { id: 'logprobs', wire: 'logprobs', valueSchema: 'boolean', group: 'output_contract', default: false },
        { id: 'top_logprobs', wire: 'top_logprobs', valueSchema: 'integer', group: 'output_contract', range: { min: 0 } },
        { id: 'post_sampling_probs', wire: 'post_sampling_probs', valueSchema: 'boolean', group: 'output_contract', default: false },
      ],
    },
    llamacpp_native: {
      template: 'llamacpp_native',
      parameters: [
        { id: 'max_output_tokens', wire: 'n_predict', valueSchema: 'integer', group: 'budget', range: { min: 1 }, default: -1 },
        { id: 'stop', wire: 'stop', valueSchema: 'string-list', group: 'budget' },
        { id: 'temperature', wire: 'temperature', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0.8 },
        { id: 'top_p', wire: 'top_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.95 },
        { id: 'top_k', wire: 'top_k', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 40 },
        { id: 'min_p', wire: 'min_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.05 },
        { id: 'typical_p', wire: 'typical_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 1 },
        { id: 'top_n_sigma', wire: 'top_n_sigma', valueSchema: 'number', group: 'sampling', default: -1 },
        { id: 'presence_penalty', wire: 'presence_penalty', valueSchema: 'number', group: 'repetition', default: 0 },
        { id: 'frequency_penalty', wire: 'frequency_penalty', valueSchema: 'number', group: 'repetition', default: 0 },
        { id: 'repeat_penalty', wire: 'repeat_penalty', valueSchema: 'number', group: 'repetition', range: { min: 0 }, default: 1 },
        { id: 'repeat_last_n', wire: 'repeat_last_n', valueSchema: 'integer', group: 'repetition', range: { min: 0 }, default: 64 },
        { id: 'mirostat', wire: 'mirostat', valueSchema: 'integer', group: 'sampling', range: { min: 0, max: 2 }, default: 0 },
        { id: 'mirostat_tau', wire: 'mirostat_tau', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 5 },
        { id: 'mirostat_eta', wire: 'mirostat_eta', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0.1 },
        { id: 'dry_multiplier', wire: 'dry_multiplier', valueSchema: 'number', group: 'repetition', range: { min: 0 }, default: 0 },
        { id: 'dry_base', wire: 'dry_base', valueSchema: 'number', group: 'repetition', range: { min: 1 }, default: 1.75 },
        { id: 'dry_allowed_length', wire: 'dry_allowed_length', valueSchema: 'integer', group: 'repetition', range: { min: 0 }, default: 2 },
        { id: 'dry_penalty_last_n', wire: 'dry_penalty_last_n', valueSchema: 'integer', group: 'repetition', range: { min: -1 }, default: -1 },
        { id: 'dry_sequence_breakers', wire: 'dry_sequence_breakers', valueSchema: 'string-list', group: 'repetition' },
        { id: 'xtc_probability', wire: 'xtc_probability', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0 },
        { id: 'xtc_threshold', wire: 'xtc_threshold', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0.1 },
        { id: 'dynatemp_range', wire: 'dynatemp_range', valueSchema: 'number', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 'dynatemp_exponent', wire: 'dynatemp_exponent', valueSchema: 'number', group: 'sampling', default: 1 },
        { id: 'samplers', wire: 'samplers', valueSchema: 'string-list', group: 'sampling' },
        { id: 'min_keep', wire: 'min_keep', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 'n_keep', wire: 'n_keep', valueSchema: 'integer', group: 'sampling', range: { min: -1 }, default: 0 },
        { id: 'n_indent', wire: 'n_indent', valueSchema: 'integer', group: 'sampling', range: { min: 0 }, default: 0 },
        { id: 't_max_predict_ms', wire: 't_max_predict_ms', valueSchema: 'integer', group: 'budget', range: { min: 0 }, default: 0 },
        { id: 'ignore_eos', wire: 'ignore_eos', valueSchema: 'boolean', group: 'budget', default: false },
        { id: 'seed', wire: 'seed', valueSchema: 'integer', group: 'reproducibility' },
        { id: 'grammar', wire: 'grammar', valueSchema: 'string', group: 'output_contract' },
        { id: 'json_schema', wire: 'json_schema', valueSchema: 'json-schema', group: 'output_contract' },
        { id: 'n_probs', wire: 'n_probs', valueSchema: 'integer', group: 'output_contract', range: { min: 0 }, default: 0 },
        { id: 'post_sampling_probs', wire: 'post_sampling_probs', valueSchema: 'boolean', group: 'output_contract', default: false },
      ],
    },
  },
  ollama: {
    openai_chat_completions: {
      template: 'openai_chat_completions',
      parameters: [
        { id: 'max_output_tokens', wire: 'max_tokens', valueSchema: 'integer', group: 'budget', range: { min: 1 } },
        { id: 'stop', wire: 'stop', valueSchema: 'string-list', group: 'budget' },
        { id: 'reasoning_effort', wire: 'reasoning_effort', valueSchema: 'string', group: 'reasoning' },
        { id: 'temperature', wire: 'temperature', valueSchema: 'number', group: 'sampling', range: { min: 0 } },
        { id: 'top_p', wire: 'top_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 } },
        { id: 'presence_penalty', wire: 'presence_penalty', valueSchema: 'number', group: 'repetition' },
        { id: 'frequency_penalty', wire: 'frequency_penalty', valueSchema: 'number', group: 'repetition' },
        { id: 'seed', wire: 'seed', valueSchema: 'integer', group: 'reproducibility' },
        { id: 'response_format', wire: 'response_format', valueSchema: 'enum', group: 'output_contract', enumValues: ['text', 'json'] },
        { id: 'json_schema', wire: 'response_format', valueSchema: 'json-schema', group: 'output_contract' },
      ],
    },
  },
  lmstudio: {
    openai_chat_completions: {
      template: 'openai_chat_completions',
      parameters: [
        { id: 'max_output_tokens', wire: 'max_tokens', valueSchema: 'integer', group: 'budget', range: { min: 1 } },
        { id: 'stop', wire: 'stop', valueSchema: 'string-list', group: 'budget' },
        { id: 'temperature', wire: 'temperature', valueSchema: 'number', group: 'sampling', range: { min: 0 } },
        { id: 'top_p', wire: 'top_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 } },
        { id: 'top_k', wire: 'top_k', valueSchema: 'integer', group: 'sampling', range: { min: 0 } },
        { id: 'presence_penalty', wire: 'presence_penalty', valueSchema: 'number', group: 'repetition' },
        { id: 'frequency_penalty', wire: 'frequency_penalty', valueSchema: 'number', group: 'repetition' },
        { id: 'repeat_penalty', wire: 'repeat_penalty', valueSchema: 'number', group: 'repetition', range: { min: 0 } },
        { id: 'seed', wire: 'seed', valueSchema: 'integer', group: 'reproducibility' },
        { id: 'json_schema', wire: 'response_format', valueSchema: 'json-schema', group: 'output_contract' },
      ],
    },
  },
  vllm: {
    openai_chat_completions: {
      template: 'vllm_extra_body',
      parameters: [
        { id: 'max_output_tokens', wire: 'max_tokens', valueSchema: 'integer', group: 'budget', range: { min: 1 } },
        { id: 'min_tokens', wire: 'min_tokens', valueSchema: 'integer', group: 'budget', range: { min: 0 }, default: 0 },
        { id: 'stop', wire: 'stop', valueSchema: 'string-list', group: 'budget' },
        { id: 'ignore_eos', wire: 'ignore_eos', valueSchema: 'boolean', group: 'budget', default: false },
        { id: 'temperature', wire: 'temperature', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 2 }, default: 1 },
        { id: 'top_p', wire: 'top_p', valueSchema: 'number', group: 'sampling', range: { minExclusive: 0, max: 1 }, default: 1 },
        { id: 'top_k', wire: 'top_k', valueSchema: 'integer', group: 'sampling', range: { min: -1 }, default: 0 },
        { id: 'min_p', wire: 'min_p', valueSchema: 'number', group: 'sampling', range: { min: 0, max: 1 }, default: 0 },
        { id: 'presence_penalty', wire: 'presence_penalty', valueSchema: 'number', group: 'repetition', range: { min: -2, max: 2 }, default: 0 },
        { id: 'frequency_penalty', wire: 'frequency_penalty', valueSchema: 'number', group: 'repetition', range: { min: -2, max: 2 }, default: 0 },
        { id: 'repeat_penalty', wire: 'repetition_penalty', valueSchema: 'number', group: 'repetition', range: { minExclusive: 0 }, default: 1 },
        { id: 'seed', wire: 'seed', valueSchema: 'integer', group: 'reproducibility' },
        { id: 'skip_special_tokens', wire: 'skip_special_tokens', valueSchema: 'boolean', group: 'output_contract', default: true },
        { id: 'response_format', wire: 'response_format', valueSchema: 'enum', group: 'output_contract', enumValues: ['text', 'json'] },
        { id: 'json_schema', wire: 'response_format', valueSchema: 'json-schema', group: 'output_contract' },
        { id: 'logprobs', wire: 'logprobs', valueSchema: 'boolean', group: 'output_contract', default: false },
        { id: 'top_logprobs', wire: 'top_logprobs', valueSchema: 'integer', group: 'output_contract', range: { min: 0 }, default: 0 },
      ],
    },
  },
};

export function isLocalEngine(engine: string | null | undefined): engine is LocalEngine {
  return engine === 'llamacpp' || engine === 'ollama' || engine === 'lmstudio' || engine === 'vllm';
}

/** Connection protocol -> parameter table channel; an unselected protocol (auto / default) uses the engine's default chat channel. A protocol without a table gets none. */
function localEngineChannel(engine: LocalEngine, transport: string | null | undefined): LocalEngineTransport | undefined {
  if (!transport || transport === 'auto' || transport === 'openai_chat_completions') return 'openai_chat_completions';
  if (engine === 'llamacpp' && transport === 'llamacpp_native') return 'llamacpp_native';
  return undefined;
}

export function localEngineGenerationProfile(
  engine: string | null | undefined,
  transport: string | null | undefined,
): GenerationParameterProfile | undefined {
  if (!isLocalEngine(engine)) return undefined;
  const channel = localEngineChannel(engine, transport);
  const table = channel ? LOCAL_ENGINE_PROFILES[engine][channel] : undefined;
  if (!table) return undefined;
  return {
    template: table.template,
    wire: Object.fromEntries(table.parameters.map((row) => [row.id, row.wire])),
    // The engine profile is a capability source the user chose explicitly but it has not been verified per model, so it is honestly marked accepted_unverified.
    parameters: table.parameters.map((row) => ({
      id: row.id,
      support: 'accepted_unverified',
      source: 'user_declared',
      group: row.group,
      valueSchema: row.valueSchema,
      ...(row.range ? { range: row.range } : {}),
      ...(row.enumValues ? { enumValues: row.enumValues } : {}),
      ...(row.default !== undefined ? { defaultDescription: row.default } : {}),
      // A locally synthesized profile is not served remotely, so whether json_schema carries strict is declared here (shared contract modelLevelFacts).
      ...(row.id === 'json_schema' ? { strict: true } : {}),
    })),
  };
}
