/**
 * Mount points of the generation parameters on the provider detail pages: both mount the panel with the default scope (editing the model default) and pass no scope / conversationId.
 * With the default scope the subtitle shows only the model name and reset clears the model default; this is asserted with the same mount shape by GenerationParameterPanel.test.tsx.
 * - Official provider page: expands in place under the model row.
 * - Relay detail page: the Parameters row in the Models group opens RelayParametersDialog and the panel is mounted inside the dialog (remounted per model key);
 *   the detail page itself no longer mounts the panel directly.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const DETAIL_DIR = path.resolve(__dirname, '../../app/providers/[providerId]');

function read(file: string): string {
  return readFileSync(path.join(DETAIL_DIR, file), 'utf8');
}

function panelMounts(source: string): string[] {
  return source.match(/<GenerationParameterPanel\b[^>]*\/>/g) ?? [];
}

describe('advanced settings mount on provider detail pages', () => {
  it('OfficialProviderDetail.tsx mounts GenerationParameterPanel where a model row expands, with the default scope', () => {
    const source = read('OfficialProviderDetail.tsx');
    expect(panelMounts(source)).toEqual(['<GenerationParameterPanel provider={provider} model={model} />']);
    expect(source).toMatch(/expandedGenerationModelId === model\.id && \(\s*<GenerationParameterPanel/);
    expect(source).toContain("from '../../../components/generation/GenerationParameterPanel'");
  });

  it('RelayDetail.tsx opens RelayParametersDialog from the Parameters row and does not mount the panel directly', () => {
    const source = read('RelayDetail.tsx');
    expect(panelMounts(source)).toEqual([]);
    expect(source).not.toContain('expandedGenerationModelId');
    expect(source).toMatch(/showParameters && provider\.models\.length > 0 && \(\s*<RelayParametersDialog/);
    expect(source).toContain("from './components/RelayParametersDialog'");
  });

  it('RelayParametersDialog.tsx mounts GenerationParameterPanel for the selected model, with the default scope', () => {
    const source = read('components/RelayParametersDialog.tsx');
    expect(panelMounts(source)).toEqual(['<GenerationParameterPanel key={model.id} provider={provider} model={model} />']);
    expect(source).toContain("from '../../../../components/generation/GenerationParameterPanel'");
  });
});
