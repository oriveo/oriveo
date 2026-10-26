import { readdirSync, readFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { INPUT_CAPABILITY_KEYS } from '../providers/capability-evidence-facade';
import { resolveRelayEnvelope } from '../providers/relay-runtime-support';
import type { MetadataProviderConfig, RelayRuntimeConfig } from './index';

const REPO_ROOT = resolve(__dirname, '../../../../..');
const WEB_ROOT = resolve(__dirname, '../../../..');

function sourceFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.next', '.next-dev', 'dist'].includes(entry.name)) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...sourceFiles(full));
    else if (/\.(ts|tsx|mts|mjs)$/.test(entry.name)) out.push(full);
  }
  return out;
}

function source(path: string): string {
  return readFileSync(resolve(__dirname, path), 'utf8');
}

describe('core ports surface', () => {
  it('exports no port type carrying legacy capability fields', () => {
    const content = source('index.ts');
    for (const field of ['attachmentSupport', 'capabilities', 'toolCall', 'capabilityControls']) {
      expect(content, `ports/index.ts must not declare ${field}`).not.toMatch(
        new RegExp(`\\b${field}\\??\\s*:`),
      );
    }
  });

  it('lets only the relay decoder import the legacy relay envelope', () => {
    const importer = /from\s+['"][^'"]*legacy-relay-envelope['"]/;
    const allowed = ['packages/core/src/providers/relay-runtime-support.ts'];
    const importers = ['packages', 'apps']
      .flatMap((dir) => sourceFiles(resolve(WEB_ROOT, dir)))
      .filter((file) => importer.test(readFileSync(file, 'utf8')))
      .map((file) => relative(WEB_ROOT, file).split('\\').join('/'))
      .sort();
    expect(importers).toEqual([...allowed].sort());
  });

  it('keeps the facade input keys equal to the input family of capability_keys.v1.json', () => {
    const contract = JSON.parse(
      readFileSync(resolve(REPO_ROOT, 'shared/model-contracts/capability_keys.v1.json'), 'utf8'),
    ) as { keys: { key: string; family: string }[] };
    const inputKeys = contract.keys.filter((entry) => entry.family === 'input').map((entry) => entry.key);
    expect(inputKeys.length).toBeGreaterThan(0);
    expect([...INPUT_CAPABILITY_KEYS].sort()).toEqual([...inputKeys].sort());
  });

  it('declares no index signature on MetadataProviderConfig', () => {
    const config: MetadataProviderConfig = { providerKind: 'openAI' };
    // @ts-expect-error undeclared keys (legacy capability bits) are not readable through the port
    const legacy: unknown = config.attachmentSupport;
    expect(legacy).toBeUndefined();
  });

  it('keeps transport envelopes opaque on the port and decodes them only via relay-runtime-support', () => {
    const envelope = {
      image: true,
      nativeFile: false,
      textFileInline: true,
      webSearch: false,
      imageGeneration: false,
      reasoning: true,
    };
    const runtimeConfig: Pick<RelayRuntimeConfig, 'transportEnvelopes'> = {
      transportEnvelopes: {
        openai_responses: envelope,
        openai_chat_completions: envelope,
        anthropic_messages: envelope,
        gemini_generate_content: envelope,
      },
    };
    // @ts-expect-error the port value carries no image field
    const portImage: unknown = runtimeConfig.transportEnvelopes.openai_responses.image;
    expect(portImage).toBe(true);
    expect(resolveRelayEnvelope('openai_responses', runtimeConfig)).toBe(envelope);
  });
});
