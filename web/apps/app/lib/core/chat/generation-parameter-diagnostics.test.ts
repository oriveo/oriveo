// @vitest-environment jsdom

import { afterEach, describe, expect, it } from 'vitest';
import {
  clearGenerationParameterDiagnostics,
  exportGenerationParameterDiagnosticsJSON,
  listGenerationParameterDiagnostics,
  recordGenerationParameterDiagnostic,
} from './generation-parameter-diagnostics';

afterEach(() => localStorage.clear());

describe('generation parameter diagnostics privacy', () => {
  it('keeps local detail but redacts model identity and never stores parameter values', () => {
    recordGenerationParameterDiagnostic({
      parameter: 'temperature',
      status: 'recovered',
      transport: 'openai_chat_completions',
      errorClass: 'unsupported_parameter',
      phase: 'before_first_token',
      modelId: 'private/local-model',
    });

    expect(listGenerationParameterDiagnostics()[0]?.modelId).toBe('private/local-model');
    const exported = exportGenerationParameterDiagnosticsJSON();
    expect(exported).toContain('temperature');
    expect(exported).toContain('unsupported_parameter');
    expect(exported).not.toContain('private/local-model');
  });

  it('rejects non-canonical parameter names and can clear history', () => {
    recordGenerationParameterDiagnostic({
      parameter: 'prompt with private text',
      status: 'recovered',
      transport: 'unknown',
      errorClass: 'unsupported_parameter',
      phase: 'before_first_token',
    });
    expect(listGenerationParameterDiagnostics()).toEqual([]);
    recordGenerationParameterDiagnostic({
      parameter: 'top_p',
      status: 'recovered',
      transport: 'unknown',
      errorClass: 'unsupported_parameter',
      phase: 'before_first_token',
    });
    clearGenerationParameterDiagnostics();
    expect(listGenerationParameterDiagnostics()).toEqual([]);
  });
});
