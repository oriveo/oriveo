import type { RelayCapabilityTestReason, RelayCapabilityTestShortTransport } from '@oriveo/core/providers/relay-capability-test';
import type {
  RelayCapabilityTestPanelKind,
  RelayCapabilityTestResults,
  RelayCapabilityTestStopReason,
} from '../../../lib/core/relay-capability-test-ops';

/**
 * Pure presentation of the capability test bottom panel (CapabilityTest board): input → header / progress / chips /
 * rows / footer / buttons / closability. The component renders only from this output; the fixture panelCases asserts this too.
 * Copy keys are relative to `pages.relayDetail`; parameterized copy uses values, and a parameter may itself be a piece of copy.
 */

export interface RelayCapabilityTestPanelText {
  key: string;
  values?: Record<string, string | number | RelayCapabilityTestPanelText>;
  /** Copy not under pages.relayDetail (web result rows reuse the model option copy from common). */
  namespace?: 'common';
}

export type RelayCapabilityTestPanelIcon = 'waiting' | 'running' | 'accepted' | 'rejected' | 'undetermined' | 'notRun';

export type RelayCapabilityTestPanelTrailing =
  | { kind: 'waiting' }
  /** seconds = seconds rounded half up to one decimal; the component formats it with the local number format. */
  | { kind: 'elapsed' | 'running'; seconds: number }
  | null;

export interface RelayCapabilityTestPanelRow {
  kind: RelayCapabilityTestPanelKind;
  title: string;
  icon: RelayCapabilityTestPanelIcon;
  subtitle: RelayCapabilityTestPanelText | null;
  trailing: RelayCapabilityTestPanelTrailing;
}

/** Fragment used by the web item probe: saved = the fragment stored for the first-send protocol; template = that protocol's built-in template (the effective fragment when none is stored). */
export type RelayCapabilityTestWebSource = 'saved' | 'template';

export interface RelayCapabilityTestPanelInput {
  transport: RelayCapabilityTestShortTransport;
  items: RelayCapabilityTestPanelKind[];
  /** Bound key name when ≥2 keys; 1 key = null (no chip, and the description row carries no name). */
  keyName: string | null;
  phase: 'running' | 'completed' | 'stopped';
  results: RelayCapabilityTestResults;
  running: { kind: RelayCapabilityTestPanelKind; elapsedMs: number } | null;
  written: boolean;
  stopReason: RelayCapabilityTestStopReason | null;
  /** Defaults to saved; only affects the running subtitle. */
  webSource?: RelayCapabilityTestWebSource;
}

export interface RelayCapabilityTestPanel {
  header: { kind: 'progress'; current: number; total: number } | { kind: 'done' } | { kind: 'stopped' };
  progressFraction: [number, number];
  chips: { transport: RelayCapabilityTestShortTransport; key: string | null };
  rows: RelayCapabilityTestPanelRow[];
  footer: RelayCapabilityTestPanelText;
  button: 'cancel' | 'done';
  dismissible: boolean;
}

const P = 'capabilityTest.panel.';

const TITLE: Record<RelayCapabilityTestPanelKind, string> = {
  text: `${P}itemText`,
  image: `${P}itemImage`,
  toolCall: `${P}itemTool`,
  web: `${P}itemWeb`,
};

const RUNNING: Record<RelayCapabilityTestPanelKind, string> = {
  text: `${P}runningText`,
  image: `${P}runningImage`,
  toolCall: `${P}runningTool`,
  web: `${P}runningWeb`,
};

const STOP: Record<RelayCapabilityTestStopReason, string> = {
  cancelled: `${P}stopCancelled`,
  connection: `${P}stopConnection`,
  protocol: `${P}stopProtocol`,
  unavailable: `${P}stopUnavailable`,
};

/** Reason sentences for "cannot tell"; server / http carry a status code. ok / rejection reasons never reach "cannot tell". */
function reasonText(reason: RelayCapabilityTestReason, status: number | undefined): RelayCapabilityTestPanelText {
  switch (reason) {
    case 'unauthorized': return { key: `${P}reasonUnauthorized` };
    case 'forbidden': return { key: `${P}reasonForbidden` };
    case 'rate_limited': return { key: `${P}reasonRateLimited` };
    case 'html': return { key: `${P}reasonHtml` };
    case 'server': return { key: `${P}reasonServer`, values: { code: status ?? 0 } };
    case 'timeout': return { key: `${P}reasonTimeout` };
    case 'http': return { key: `${P}reasonHttp`, values: { code: status ?? 0 } };
    case 'network':
    default:
      return { key: `${P}reasonNetwork` };
  }
}

/** One decimal, rounded half up. */
export function relayCapabilityTestSeconds(elapsedMs: number): number {
  return Math.round(Math.max(0, elapsedMs) / 100) / 10;
}

function finishedRow(
  kind: RelayCapabilityTestPanelKind,
  result: NonNullable<RelayCapabilityTestResults[RelayCapabilityTestPanelKind]>,
  written: boolean,
): Pick<RelayCapabilityTestPanelRow, 'icon' | 'subtitle'> {
  if (result.verdict === 'undetermined') {
    return { icon: 'undetermined', subtitle: { key: `${P}undetermined`, values: { reason: reasonText(result.reason, result.status) } } };
  }
  if (kind === 'web') {
    // Web item = web-search probe result: the same sentence whether written or not, without parameters.
    if (result.verdict === 'searched') return { icon: 'accepted', subtitle: { key: 'modelOptionsRelayWebSearchConfirmed', namespace: 'common' } };
    if (result.verdict === 'rejected') return { icon: 'rejected', subtitle: { key: 'modelOptionsRelayWebRejected', namespace: 'common' } };
    return { icon: 'undetermined', subtitle: { key: 'modelOptionsRelayWebNoSearchInTest', namespace: 'common' } };
  }
  if (kind === 'text') {
    if (result.verdict === 'accepted') return { icon: 'accepted', subtitle: { key: `${P}textOk` } };
    return result.reason === 'not_found'
      ? { icon: 'rejected', subtitle: { key: `${P}textNotFound` } }
      : { icon: 'rejected', subtitle: { key: `${P}textRejected`, values: { code: result.status ?? 0 } } };
  }
  if (result.verdict === 'notObserved') {
    // A reply exists but no vision / tool evidence: not written, same icon as cannot tell.
    return { icon: 'undetermined', subtitle: { key: kind === 'image' ? `${P}imageNotObserved` : `${P}toolNotObserved` } };
  }
  if (result.verdict === 'accepted') {
    return { icon: 'accepted', subtitle: { key: written ? `${P}supportedSaved` : 'capabilityTest.supported' } };
  }
  const rejectedSaved = kind === 'image' ? `${P}imageRejected` : `${P}toolRejected`;
  return { icon: 'rejected', subtitle: { key: written ? rejectedSaved : 'capabilityTest.unsupported' } };
}

export function relayCapabilityTestPanel(input: RelayCapabilityTestPanelInput): RelayCapabilityTestPanel {
  const { items, results, phase } = input;
  const total = items.length;
  const finished = items.filter((kind) => results[kind]).length;
  const textFailed = results.text !== undefined && results.text.verdict !== 'accepted';
  const written = phase === 'completed' && input.written;
  const template = input.webSource === 'template';

  const rows = items.map((kind): RelayCapabilityTestPanelRow => {
    const title = TITLE[kind];
    const result = results[kind];
    if (result) {
      return {
        kind,
        title,
        ...finishedRow(kind, result, written),
        trailing: { kind: 'elapsed', seconds: relayCapabilityTestSeconds(result.elapsedMs) },
      };
    }
    if (phase === 'running' && input.running?.kind === kind) {
      return {
        kind,
        title,
        icon: 'running',
        subtitle: { key: kind === 'web' && template ? `${P}runningWebDefault` : RUNNING[kind] },
        trailing: { kind: 'running', seconds: relayCapabilityTestSeconds(input.running.elapsedMs) },
      };
    }
    if (phase === 'stopped') return { kind, title, icon: 'notRun', subtitle: { key: `${P}notTested` }, trailing: null };
    if (phase === 'completed' || textFailed) {
      return { kind, title, icon: 'notRun', subtitle: { key: `${P}notRun` }, trailing: null };
    }
    return { kind, title, icon: 'waiting', subtitle: null, trailing: { kind: 'waiting' } };
  });

  const runningIndex = input.running ? items.indexOf(input.running.kind) : -1;
  const header: RelayCapabilityTestPanel['header'] = phase === 'running'
    ? { kind: 'progress', current: runningIndex >= 0 ? runningIndex + 1 : Math.min(finished + 1, total), total }
    : phase === 'completed' ? { kind: 'done' } : { kind: 'stopped' };

  // When the list contains a web item, switch to the description that says "one of them will search the web".
  const withWeb = items.includes('web');
  const footer: RelayCapabilityTestPanelText = phase === 'running'
    ? input.keyName !== null
      ? { key: withWeb ? `${P}infoWebNamedKey` : `${P}infoNamedKey`, values: { count: total, key: input.keyName } }
      : { key: withWeb ? `${P}infoWeb` : `${P}info`, values: { count: total } }
    : phase === 'completed'
      ? { key: written ? `${P}footerSaved` : `${P}footerNothing` }
      : { key: `${P}stopped`, values: { reason: { key: STOP[input.stopReason ?? 'cancelled'] } } };

  return {
    header,
    progressFraction: [phase === 'completed' ? total : finished, total],
    chips: { transport: input.transport, key: input.keyName },
    rows,
    footer,
    button: phase === 'running' ? 'cancel' : 'done',
    dismissible: phase !== 'running',
  };
}
