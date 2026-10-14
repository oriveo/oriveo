/** Sample page names (the same list as iOS `RelayFamilyDebugShots`, exact casing). */
export const RELAY_SHOT_PAGES = [
  'relayDetail',
  'relayDetailIssue',
  'localDetail',
  'relayKeys',
  'relayKeyInput',
  'relayKeysAdded',
  'relayLibrary',
  'relayLibraryLast',
  'relayLibraryByKey',
  'relayAdvanced',
  'relayAdvancedFixed',
  'relayCapabilityTest',
  'relayCapabilityTestWeb',
  'relayWebSearch',
  'relayWebSearchRejected',
  'relayEdit',
  'relayEditFailure',
  'localEdit',
  'relayManualSetup',
  'relayManualSetupFailure',
  'relaySetupModels',
  'relaySetupModelsAlert',
  'relaySetup',
] as const;

export type RelayShotPage = (typeof RELAY_SHOT_PAGES)[number];

export function isRelayShotPage(value: string): value is RelayShotPage {
  return (RELAY_SHOT_PAGES as readonly string[]).includes(value);
}
