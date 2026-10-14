import { readFileSync } from 'node:fs';
import path from 'node:path';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RelaySetupStepTwo } from './RelaySetupStepTwo';

// RL2-FOOTER-01 step 2 footer (hint + Save (N selected)) is fixed at the bottom of the viewport.

const ROOT = process.cwd();
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');
const cssRule = (css: string, selector: string) =>
  new RegExp(`(^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^{}]*)\\}`).exec(css)?.[2] ?? '';

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('../../../../lib/hooks/useIsDarkTheme', () => ({
  useIsDarkTheme: () => false,
}));

describe('RL2-FOOTER-01 step 2 footer is fixed at the bottom of the viewport', () => {
  it('page = a column as tall as the viewport: middle scroll area + footer (hint + Save), the footer does not scroll away with the list', () => {
    render(
      <RelaySetupStepTwo
        host="relay-demo.example"
        keyCount={1}
        totalCount={0}
        query=""
        onQueryChange={() => undefined}
        groups={[]}
        fullGroups={[]}
        selected={new Set()}
        isExpanded={() => false}
        onToggleGroup={() => undefined}
        onToggleModel={() => undefined}
        onSelectGroup={() => undefined}
        protocolOf={() => 'Chat'}
        keyChips={{}}
        onAddManual={() => undefined}
        onOpenAddManual={() => undefined}
        addManualHint={false}
        saving={false}
        saveFailure={null}
        onSave={() => undefined}
        onBack={() => undefined}
      />,
    );
    const save = screen.getByTestId('relay_setup_models_save_button');
    const footer = save.parentElement!;
    const step = footer.parentElement!;
    expect(step.className).toMatch(/modelsStep/);
    // The footer is the last direct child of step 2, preceded by a single scroll area (title, search, groups and manual add are all inside it).
    const children = [...step.children];
    expect(children.at(-1)).toBe(footer);
    const scroll = children.find((child) => child.hasAttribute('data-models-scroll'))!;
    expect(scroll).toBeTruthy();
    expect(children.filter((child) => child !== footer && child !== scroll).every((child) => child.getAttribute('role') === 'dialog' || child.tagName === 'DIALOG')).toBe(true);
    expect(scroll.querySelector('[data-testid="relay_setup_models_add_manual_button"]')).toBeTruthy();
    expect(footer.textContent).toContain('twoStep.saveNote');

    const css = read('app/providers/relay/new/RelaySetup.module.css');
    // The whole page = viewport height; no bottom padding is left for streaming content any more.
    const page = cssRule(css, '.page:has(> .modelsStep)');
    expect(page).toMatch(/display:\s*flex/);
    expect(page).toMatch(/flex-direction:\s*column/);
    expect(page).toMatch(/height:\s*100dvh/);
    expect(page).toMatch(/padding-bottom:\s*0/);
    const stepRule = cssRule(css, '.modelsStep');
    expect(stepRule).toMatch(/flex:\s*1 1 auto/);
    expect(stepRule).toMatch(/min-height:\s*0/);
    const scrollRule = cssRule(css, '.modelsScroll');
    expect(scrollRule).toMatch(/flex:\s*1 1 auto/);
    expect(scrollRule).toMatch(/min-height:\s*0/);
    expect(scrollRule).toMatch(/overflow-y:\s*auto/);
    expect(cssRule(css, '.modelsStep > .actionBar')).toMatch(/flex:\s*none/);
  });
});
