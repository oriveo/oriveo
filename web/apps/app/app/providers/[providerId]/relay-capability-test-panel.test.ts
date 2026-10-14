import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  relayCapabilityTestPanel,
  type RelayCapabilityTestPanelInput,
  type RelayCapabilityTestPanelText,
} from './relay-capability-test-panel';

/* Fixture (source of truth): the shared test-fixtures/relay/capability-test.v1.json panelCases (string ids use Android resource names) */

interface PanelCase {
  caseId: string;
  transport: RelayCapabilityTestPanelInput['transport'];
  items: RelayCapabilityTestPanelInput['items'];
  keyName: string | null;
  phase: RelayCapabilityTestPanelInput['phase'];
  results: RelayCapabilityTestPanelInput['results'];
  running?: RelayCapabilityTestPanelInput['running'];
  written?: boolean;
  stopReason?: RelayCapabilityTestPanelInput['stopReason'];
  webSource?: RelayCapabilityTestPanelInput['webSource'];
  expect: Record<string, unknown>;
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'capability-test.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as { panelCases: { cases: PanelCase[] } };
    dir = path.dirname(dir);
  }
  throw new Error('capability-test.v1.json not found');
})();

/** Android resource name → this platform's key (relative to pages.relayDetail). */
const ANDROID_TO_WEB: Record<string, string> = {
  relay_cap_test_title: 'capabilityTest.panel.title',
  relay_cap_test_progress: 'capabilityTest.panel.progress',
  relay_cap_test_done_badge: 'capabilityTest.panel.doneBadge',
  relay_cap_test_stopped_badge: 'capabilityTest.panel.stoppedBadge',
  relay_cap_test_item_text: 'capabilityTest.panel.itemText',
  relay_cap_test_item_image: 'capabilityTest.panel.itemImage',
  relay_cap_test_item_tool: 'capabilityTest.panel.itemTool',
  relay_cap_test_running_text: 'capabilityTest.panel.runningText',
  relay_cap_test_running_image: 'capabilityTest.panel.runningImage',
  relay_cap_test_running_tool: 'capabilityTest.panel.runningTool',
  relay_cap_test_waiting: 'capabilityTest.panel.waiting',
  relay_cap_test_text_ok: 'capabilityTest.panel.textOk',
  relay_cap_test_supported_saved: 'capabilityTest.panel.supportedSaved',
  relay_cap_test_image_rejected: 'capabilityTest.panel.imageRejected',
  relay_cap_test_tool_rejected: 'capabilityTest.panel.toolRejected',
  relay_cap_test_image_not_observed: 'capabilityTest.panel.imageNotObserved',
  relay_cap_test_tool_not_observed: 'capabilityTest.panel.toolNotObserved',
  relay_cap_test_text_not_found: 'capabilityTest.panel.textNotFound',
  relay_cap_test_text_rejected: 'capabilityTest.panel.textRejected',
  relay_cap_test_undetermined: 'capabilityTest.panel.undetermined',
  relay_cap_test_reason_unauthorized: 'capabilityTest.panel.reasonUnauthorized',
  relay_cap_test_reason_forbidden: 'capabilityTest.panel.reasonForbidden',
  relay_cap_test_reason_rate_limited: 'capabilityTest.panel.reasonRateLimited',
  relay_cap_test_reason_html: 'capabilityTest.panel.reasonHtml',
  relay_cap_test_reason_server: 'capabilityTest.panel.reasonServer',
  relay_cap_test_reason_timeout: 'capabilityTest.panel.reasonTimeout',
  relay_cap_test_reason_network: 'capabilityTest.panel.reasonNetwork',
  relay_cap_test_reason_http: 'capabilityTest.panel.reasonHttp',
  relay_cap_test_not_run: 'capabilityTest.panel.notRun',
  relay_cap_test_info_named_key: 'capabilityTest.panel.infoNamedKey',
  relay_cap_test_info: 'capabilityTest.panel.info',
  relay_cap_test_footer_saved: 'capabilityTest.panel.footerSaved',
  relay_cap_test_footer_nothing: 'capabilityTest.panel.footerNothing',
  relay_cap_test_stopped: 'capabilityTest.panel.stopped',
  relay_cap_test_stop_cancelled: 'capabilityTest.panel.stopCancelled',
  relay_cap_test_stop_connection: 'capabilityTest.panel.stopConnection',
  relay_cap_test_stop_protocol: 'capabilityTest.panel.stopProtocol',
  relay_cap_test_stop_unavailable: 'capabilityTest.panel.stopUnavailable',
  relay_cap_test_elapsed: 'capabilityTest.panel.elapsed',
  relay_cap_test_elapsed_running: 'capabilityTest.panel.elapsedRunning',
  relay_cap_test_not_tested: 'capabilityTest.panel.notTested',
  relay_capability_test_supported: 'capabilityTest.supported',
  relay_capability_test_unsupported: 'capabilityTest.unsupported',
  // Web search item (web-search probe result); result rows reuse the model option copy from common.
  relay_cap_test_item_web: 'capabilityTest.panel.itemWeb',
  relay_cap_test_running_web: 'capabilityTest.panel.runningWeb',
  relay_cap_test_info_web: 'capabilityTest.panel.infoWeb',
  relay_cap_test_info_web_named_key: 'capabilityTest.panel.infoWebNamedKey',
  model_options_relay_web_search_confirmed: 'common:modelOptionsRelayWebSearchConfirmed',
  model_options_relay_web_no_search_in_test: 'common:modelOptionsRelayWebNoSearchInTest',
  model_options_relay_web_rejected: 'common:modelOptionsRelayWebRejected',
  // Running subtitle of the default-settings web item.
  relay_cap_test_running_web_default: 'capabilityTest.panel.runningWebDefault',
};
const WEB_TO_ANDROID = Object.fromEntries(Object.entries(ANDROID_TO_WEB).map(([android, web]) => [web, android]));

function androidID(key: string): string {
  const id = WEB_TO_ANDROID[key];
  if (!id) throw new Error(`no Android id for ${key}`);
  return id;
}

/** Full copy key: the common namespace is written as "common:<key>", others are relative to pages.relayDetail. */
function qualified(text: RelayCapabilityTestPanelText): string {
  return text.namespace ? `${text.namespace}:${text.key}` : text.key;
}

/** This platform's structured copy → the fixture's subtitleArg notation ("<id>", "<code>" or "<id>:<code>"). */
function subtitleArgOf(text: RelayCapabilityTestPanelText): string | undefined {
  const reason = text.values?.reason;
  if (reason && typeof reason === 'object') {
    const code = reason.values?.code;
    return code === undefined ? androidID(reason.key) : `${androidID(reason.key)}:${code}`;
  }
  const code = text.values?.code;
  return code === undefined ? undefined : String(code);
}

describe('Capability test panel: pure presentation', () => {
  it.each(fixture.panelCases.cases.map((item) => [item.caseId, item] as const))('RD4-PANEL-%s', (_caseId, item) => {
    const panel = relayCapabilityTestPanel({
      transport: item.transport,
      items: item.items,
      keyName: item.keyName,
      phase: item.phase,
      results: item.results,
      running: item.running ?? null,
      written: item.written ?? false,
      stopReason: item.stopReason ?? null,
      ...(item.webSource !== undefined ? { webSource: item.webSource } : {}),
    });

    const header = panel.header.kind === 'progress' ? { progress: [panel.header.current, panel.header.total] } : panel.header.kind === 'done' ? 'done' : 'stopped';
    const rows = panel.rows.map((row) => {
      const subtitleArg = row.subtitle ? subtitleArgOf(row.subtitle) : undefined;
      return {
        kind: row.kind,
        icon: row.icon,
        subtitle: row.subtitle ? androidID(qualified(row.subtitle)) : null,
        ...(subtitleArg !== undefined ? { subtitleArg } : {}),
        trailing: row.trailing === null
          ? null
          : row.trailing.kind === 'waiting'
            ? 'waiting'
            : `${row.trailing.kind}:${row.trailing.seconds.toFixed(1)}`,
      };
    });
    const expected = item.expect as { rows: Array<Record<string, unknown>> };
    const footerValues = panel.footer.values ?? {};
    const footer = {
      key: androidID(qualified(panel.footer)),
      ...(footerValues.count !== undefined ? { count: footerValues.count } : {}),
      ...(footerValues.key !== undefined ? { keyName: footerValues.key } : {}),
      ...(footerValues.reason && typeof footerValues.reason === 'object' ? { reason: androidID(footerValues.reason.key) } : {}),
    };

    expect({
      header,
      progressFraction: panel.progressFraction,
      chips: panel.chips,
      rows,
      footer,
      button: panel.button,
      dismissible: panel.dismissible,
    }).toEqual(expected);
  });
});

describe('Web first frame (before any request is sent)', () => {
  it('first frame already lists the web item (waiting), the footer uses infoWeb / infoWebNamedKey, and the count includes web', () => {
    const first = (keyName: string | null) => relayCapabilityTestPanel({
      transport: 'chat',
      items: ['text', 'web'],
      keyName,
      phase: 'running',
      results: {},
      running: { kind: 'text', elapsedMs: 0 },
      written: false,
      stopReason: null,
    });
    const panel = first(null);
    expect(panel.rows.map((row) => [row.kind, row.icon])).toEqual([['text', 'running'], ['web', 'waiting']]);
    expect(panel.footer).toEqual({ key: 'capabilityTest.panel.infoWeb', values: { count: 2 } });
    expect(first('Backup').footer).toEqual({ key: 'capabilityTest.panel.infoWebNamedKey', values: { count: 2, key: 'Backup' } });
  });
});
