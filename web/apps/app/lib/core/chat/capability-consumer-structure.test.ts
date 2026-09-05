import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP_ROOT = process.cwd();

function source(path: string): string {
  return readFileSync(resolve(APP_ROOT, path), 'utf8');
}

describe('H6 Web capability consumer structure', () => {
  it('keeps covered filters, sorting, skill routing, and model badges off raw evidence fields', () => {
    const consumers = [
      'lib/core/skills/query.ts',
      'app/providers/[providerId]/model-browser-groups.ts',
      'components/chat/ModelMetaInline.tsx',
      'components/chat/ModelSwitcher/ModelRowItem.tsx',
      'components/chat/ModelSwitcher/model-switcher-data.ts',
    ];
    const forbidden = [
      /\.reasoningModeAvailable\b/,
      /\.toolCall\b/,
      /capabilities(?:\?|)\.includes\(\s*['"](?:reasoning|image|vision|web|tool|tools)['"]\s*(?:as never)?\)/,
      /capabilities\s*=\s*\{\s*model\.capabilities\s*\}/,
    ];

    for (const path of consumers) {
      const content = source(path);
      for (const pattern of forbidden) {
        expect(content, `${path} must consume the evidence facade`).not.toMatch(pattern);
      }
    }
  });

  it('keeps core capability projections independent from React component modules', () => {
    const coreSources = [
      'lib/core/chat/model-capability-presentation.ts',
      'lib/core/skills/query.ts',
    ];
    for (const path of coreSources) {
      expect(source(path), `${path} must not import components`).not.toMatch(/from\s+['"][^'"]*components\//);
    }
    expect(source('lib/core/chat/model-capability-presentation.ts')).toContain(
      "resolveModelCapabilityEvidence({ key, provider, model })",
    );
  });

  it('passes the real Provider at every production ModelBrowser and ModelMetaInline call site', () => {
    const files = [
      'app/providers/[providerId]/OfficialProviderDetail.tsx',
      'app/providers/[providerId]/RelayDetail.tsx',
      'app/providers/[providerId]/ModelBrowser.tsx',
      'components/chat/ModelSwitcher/CatalogModelRow.tsx',
    ];

    for (const path of files) {
      const content = source(path);
      for (const tag of ['ModelBrowser', 'ModelMetaInline']) {
        const calls = [...content.matchAll(new RegExp(`<${tag}\\b[\\s\\S]*?\\/>`, 'g'))];
        for (const call of calls) {
          expect(call[0], `${path} ${tag} must receive a Provider`).toMatch(/\bprovider=\{/);
        }
      }
    }
  });

  it('keeps long-lived browser, badge, and switcher projections subscribed to evidence TTL', () => {
    for (const path of [
      'app/providers/[providerId]/ModelBrowser.tsx',
      'components/chat/ModelMetaInline.tsx',
      'components/chat/ModelSwitcher.tsx',
    ]) {
      expect(source(path), `${path} must refresh when evidence expires`).toMatch(
        /useCapabilityEvidence(?:Collection)?Expiry/,
      );
    }
    expect(source('components/chat/ModelSwitcher/hooks/useModelSwitcherData.ts')).toContain(
      'capabilityEvidenceTick',
    );
    expect(source('app/providers/[providerId]/ModelBrowser.tsx')).toContain(
      'observeEvidenceExpiry={false}',
    );
    expect(source('components/chat/ModelSwitcher/CatalogModelRow.tsx')).toContain(
      'observeEvidenceExpiry={false}',
    );
    expect(source('components/chat/ModelSwitcher/ModelRowItem.tsx')).not.toContain(
      'useCapabilityEvidenceExpiry',
    );
  });

  it('keeps generation panel editability in the shared facade projection', () => {
    // The editability check is collapsed into `generationParameterAdjustable` (stream-options),
    // which internally combines the declared state, the evidence state and the exact identity into a
    // presentation class. The model picker's "supports this parameter" filter asks the same
    // function - writing it twice produces models that pass the filter but open greyed out.
    const panel = source('components/generation/GenerationParameterPanel.tsx');
    expect(panel).toContain('generationParameterAdjustable(profile?.wire[id], parameter.support, evidence)');
    expect(panel).not.toMatch(/const\s+editableByEvidence\s*=\s*evidence\./);
    expect(panel).not.toContain('isCapabilityEvidenceEditable(');

    const judge = source('lib/core/chat/stream-options.ts');
    expect(judge).toContain('effectiveGenerationSupport(declaredSupport, evidence)');
    expect(judge).toContain('return generationParameterAdjustable(profile.wire[parameterId], parameter.support, evidence);');
    expect(source('components/chat/ModelSwitcher/model-switcher-data.ts'))
      .toContain('modelSupportsGenerationParameter(provider, model, requiredGenerationParameterId)');
  });

  /**
   * A greyed-out "not adjustable" state must come with a primary action, or it is a dead end.
   * The chain has four segments (ChatView opens the picker -> composer forwards -> the model option
   * popover forwards -> the panel renders the button); break one and it degrades into a dead button
   * or renders nothing at all. Each segment is pinned here, so deleting any of them fails.
   */
  it('wires the D4 not-adjustable primary action from ChatView down to the panel row', () => {
    const chatView = source('components/chat/ChatView.tsx');
    expect(chatView).toContain('onFindModelsSupportingParameter={handleFindModelsSupportingParameter}');
    expect(chatView).toContain('requiredGenerationParameterId={switcherRequiredParameterId}');

    expect(source('components/chat/InputComposer.tsx'))
      .toContain('onFindModelsSupportingParameter={onFindModelsSupportingParameter}');
    expect(source('components/chat/ModelOptionsPopover.tsx'))
      .toContain('onFindSupportedModels: onFindModelsSupportingParameter');

    const panel = source('components/generation/GenerationParameterPanel.tsx');
    expect(panel).toContain("presentation.classId === 'not_adjustable'");
    expect(panel).toContain('generationParameterFindSupportedModels');
    // Mount points with no picker to open (the two paths on the provider detail page) fall back to
    // an inline read-only list rather than the dead end of rendering nothing. The candidate check
    // may only borrow modelSupportsGenerationParameter.
    expect(panel).toContain('listCandidates: () => supportedModelNames(provider, model, id)');
    expect(panel).toContain('modelSupportsGenerationParameter(provider, candidate, parameterId)');
  });
});
