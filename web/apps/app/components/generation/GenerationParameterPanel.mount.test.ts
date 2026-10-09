/**
 * Mount point for the in-place expansion under a model row on the provider detail pages: both detail pages mount the new panel with the default scope (editing the model default)
 * and pass no scope / conversationId. With the default scope the subtitle shows only the model name and reset clears the model default; this is asserted with the same mount shape by
 * GenerationParameterPanel.test.tsx.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const DETAIL_PAGES = ['OfficialProviderDetail.tsx', 'RelayDetail.tsx'];

describe('advanced settings mount on provider detail pages', () => {
  it.each(DETAIL_PAGES)('%s mounts GenerationParameterPanel where a model row expands, with the default scope', (file) => {
    const source = readFileSync(path.resolve(__dirname, '../../app/providers/[providerId]', file), 'utf8');
    const mounts = source.match(/<GenerationParameterPanel\b[^>]*\/>/g) ?? [];
    expect(mounts).toEqual(['<GenerationParameterPanel provider={provider} model={model} />']);
    expect(source).toMatch(/expandedGenerationModelId === model\.id && \(\s*<GenerationParameterPanel/);
    expect(source).toContain("from '../../../components/generation/GenerationParameterPanel'");
  });
});
