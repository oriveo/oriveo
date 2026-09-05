import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  GENERATION_PRESENTATION_CLASSES,
  GENERATION_SUPPORT_MAP,
  generationSupportPresentation,
  type GenerationSupportState,
} from '../generation-support-presentation';

interface ContractClass {
  classId: string;
  renders: boolean;
  control: string;
  labelKey?: string;
}
interface Contract {
  schema: { support: string[] };
  presentationClasses: {
    classes: ContractClass[];
    supportMap: Record<string, { class: string; detailKey?: string }>;
  };
  [key: string]: unknown;
}

const contract = JSON.parse(readFileSync(
  resolve(process.cwd(), '../../../shared/model-contracts/generation_parameter_contract.v1.json'),
  'utf8',
)) as Contract;

/** Every `support` literal appearing anywhere in the contract file, fixtures included; trusting the schema alone is not enough. */
function supportLiterals(node: unknown, found = new Set<string>()): Set<string> {
  if (Array.isArray(node)) {
    for (const item of node) supportLiterals(item, found);
  } else if (node && typeof node === 'object') {
    for (const [key, value] of Object.entries(node as Record<string, unknown>)) {
      if (key === 'support' && typeof value === 'string') found.add(value);
      supportLiterals(value, found);
    }
  }
  return found;
}

describe('generation support presentation table', () => {
  it('matches the presentationClasses of the shared contract byte for byte', () => {
    for (const declared of contract.presentationClasses.classes) {
      const mirrored = GENERATION_PRESENTATION_CLASSES[
        declared.classId as keyof typeof GENERATION_PRESENTATION_CLASSES
      ];
      expect(mirrored, `contract class ${declared.classId} is missing from the mirror table`).toBeTruthy();
      expect(mirrored.renders).toBe(declared.renders);
      expect(mirrored.control).toBe(declared.control);
      expect(mirrored.labelKey).toBe(declared.labelKey);
    }
    expect(Object.keys(GENERATION_PRESENTATION_CLASSES).sort())
      .toEqual(contract.presentationClasses.classes.map((item) => item.classId).sort());

    for (const [support, declared] of Object.entries(contract.presentationClasses.supportMap)) {
      const mirrored = GENERATION_SUPPORT_MAP[support as GenerationSupportState];
      expect(mirrored, `${support} from the contract supportMap is missing from the mirror table`).toBeTruthy();
      expect(mirrored.classId).toBe(declared.class);
      expect(mirrored.detailKey).toBe(declared.detailKey);
    }
    expect(Object.keys(GENERATION_SUPPORT_MAP).sort())
      .toEqual(Object.keys(contract.presentationClasses.supportMap).sort());
  });

  it('every support value appearing in the contract has a presentation class, so an unmapped ninth state fails here instead of silently rendering as unknown', () => {
    const literals = supportLiterals(contract);
    // With no support literal in the fixtures the loop below would degrade into an empty assertion.
    expect(literals.size).toBeGreaterThanOrEqual(contract.schema.support.length);
    for (const support of [...literals, ...contract.schema.support]) {
      expect(support in GENERATION_SUPPORT_MAP, `support=${support} from the contract has no presentation class`).toBe(true);
    }
  });

  it('stays quiet in the normal case: supported / accepted render no label', () => {
    for (const support of ['supported', 'accepted'] as const) {
      const presentation = generationSupportPresentation(support);
      expect(presentation.renders).toBe(false);
      expect(presentation.labelKey).toBeUndefined();
    }
    // Counter-check: every other state must have a label and sub-copy, or collapsing them into a table degrades into saying nothing at all.
    for (const support of Object.keys(GENERATION_SUPPORT_MAP)) {
      if (support === 'supported' || support === 'accepted') continue;
      const presentation = generationSupportPresentation(support);
      expect(presentation.renders, support).toBe(true);
      expect(presentation.labelKey, support).toBeTruthy();
      expect(presentation.detailKey, support).toBeTruthy();
    }
  });

  it('the not_adjustable class disables the control while the other classes stay editable', () => {
    expect(generationSupportPresentation('fixed').control).toBe('disabled');
    expect(generationSupportPresentation('unsupported').control).toBe('disabled');
    expect(generationSupportPresentation('mode_dependent').control).toBe('disabled');
    expect(generationSupportPresentation('unknown').control).toBe('editable');
    expect(generationSupportPresentation('accepted_unverified').control).toBe('editable');
  });
});
