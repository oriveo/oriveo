import type { Provider, RelayKeyStatusState } from '@oriveo/shared';
import {
  listingKeysOf,
  relayEffectiveKeyID,
  relayKeyIDs,
  relayKeyList,
  relayKeyRows,
  type RelayKeyOp,
  type RelayKeyRow,
} from '@oriveo/shared/relay/relay-keys';
import { relayProviderRequiresCredential } from '../../../lib/core/providers/relay-runtime-support';

/**
 * Keys page board (view state). Reads only the RK-2 read model (relayKeyRows);
 * status comes only from `RelayKey.status`, with no separate probe. Writes always go through `applyRelayKeyOperation`, not here.
 * Copy keys always carry a namespace and are resolved by the root translator.
 */

export type KeyText = { key: string; values?: Record<string, string | number> };
export type RelayKeyAction = 'viewModels' | 'rename' | 'replace' | 'moveUp' | 'moveDown' | 'delete';
/** Mark before the status word (BOARD-KEYS-08 / 11): normal = dot, the rest = warning, fetching = spinner; never detected draws nothing. */
export type RelayKeyStatusMark = 'dot' | 'warning' | 'progress';

export interface RelayKeyLastStatus {
  httpStatus: number;
  statusKey: string;
  checkedAt?: string;
}

export interface RelayKeysPageRow {
  id: string;
  /** Name; when there is no name, the mask is used. */
  title: string;
  preview: string;
  /** Shows "Primary" on the first key when there are >=2 keys. */
  primaryBadge: boolean;
  /** null when never detected (and not fetching): neither a status word nor a mark is drawn. */
  statusKey: string | null;
  statusMark: RelayKeyStatusMark | null;
  catalog: KeyText;
  /** This key's catalog count (same listing criterion as listingKeysOf); when > 0 the first panel item is "View models (N)". */
  catalogCount: number;
  enabledUsing: KeyText;
  /** "Last: <code> <status word> · <time>" when not ok and there is an httpStatus. */
  lastStatus?: RelayKeyLastStatus;
  /** The primary key cannot be deleted (a hint sentence is given when there are >=2 keys). */
  deleteBlocked: boolean;
  /** Note in the action panel (primary key only: move another key to first place before it can be deleted). */
  panelNoteKey: string | null;
  actions: RelayKeyAction[];
  /** Ids of the enabled models that use it (the delete confirmation lists them one by one). */
  usingModelIDs: string[];
}

export interface RelayKeysBoard {
  host: string;
  count: number;
  /** A single key (fewer than 2, including a single-entry list): only replace key, via the existing single-key change-Key path. */
  implicit: boolean;
  showsPrimaryHint: boolean;
  /** "Add key" is given only when the connection needs credentials. */
  canAdd: boolean;
  rows: RelayKeysPageRow[];
  /** Rows in the keys card: each key + a final "Add key" row (when the connection needs credentials). */
  listItems: RelayKeysListItem[];
  /** The "Actions for each key" note card when there are >=2 keys; empty for a single key. */
  actionNotes: RelayKeyActionNote[];
  /** Two footer sentences: this page has no save button, so first say changes apply immediately, then the status source. */
  footnoteKeys: string[];
}

export type RelayKeysListItem = { kind: 'key'; id: string } | { kind: 'add'; id: 'add' };

export interface RelayKeyActionNote {
  action: 'rename' | 'replace' | 'delete';
  noteKey: string;
}

const ACTION_NOTES: RelayKeyActionNote[] = [
  { action: 'rename', noteKey: 'pages.relayDetail.keyRenameHint' },
  { action: 'replace', noteKey: 'pages.relayDetail.keyReplaceHint' },
  { action: 'delete', noteKey: 'pages.relayDetail.keyDeleteHint' },
];

const STATUS_KEYS: Record<RelayKeyStatusState, string> = {
  ok: 'pages.relayDetail.keyStatusOk',
  invalid: 'pages.relayDetail.keyStatusInvalid',
  denied: 'pages.relayDetail.keyStatusDenied',
  limited: 'pages.relayDetail.keyStatusLimited',
  failed: 'pages.relayDetail.keyStatusFailed',
};

export function relayKeyStatusKey(state: RelayKeyStatusState): string;
export function relayKeyStatusKey(state: RelayKeyStatusState | null): string | null;
export function relayKeyStatusKey(state: RelayKeyStatusState | null): string | null {
  // Unrecognized status values are treated as the default.
  return (state && STATUS_KEYS[state]) ?? null;
}

/** Recognized status values; unrecognized ones (old / new version values from decoding) are treated as never detected. */
export function knownRelayKeyStatusState(state: string | null | undefined): RelayKeyStatusState | null {
  return state && Object.prototype.hasOwnProperty.call(STATUS_KEYS, state) ? state as RelayKeyStatusState : null;
}

export function relayKeyCatalogText(count: number): KeyText {
  return count > 0
    ? { key: 'pages.relayDetail.keyCatalogCount', values: { count } }
    : { key: 'pages.relayDetail.keyCatalogNone' };
}

/** Name or mask. */
export function relayKeyTitle(row: Pick<RelayKeyRow, 'name' | 'preview'>): string {
  const name = row.name?.trim();
  return name || row.preview;
}

function hostOf(baseURLText: string | null | undefined): string {
  const raw = (baseURLText ?? '').trim();
  try {
    return new URL(raw.includes('://') ? raw : `https://${raw}`).host;
  } catch {
    return raw;
  }
}

export function relayKeyStatusMark(state: RelayKeyStatusState | null): RelayKeyStatusMark | null {
  const known = knownRelayKeyStatusState(state);
  if (known === null) return null;
  return known === 'ok' ? 'dot' : 'warning';
}

/** `fetchingKeyIDs`: the keys in the page state currently fetching the catalog (BOARD-KEYS-11); these rows show fetching and carry no last status. */
export function relayKeysBoard(
  provider: Provider,
  fetchingKeyIDs: ReadonlySet<string> = new Set(),
): RelayKeysBoard {
  const entries = relayKeyList(provider);
  const rows = relayKeyRows(provider);
  const count = rows.length;
  // A single key is always judged as <2 keys, regardless of whether there is a list: a single-entry list still has only replace key.
  const implicit = count < 2;
  const canAdd = relayProviderRequiresCredential(provider);
  return {
    host: hostOf(provider.baseURLText),
    count,
    implicit,
    showsPrimaryHint: count >= 2,
    canAdd,
    listItems: [
      ...rows.map((row) => ({ kind: 'key' as const, id: row.id })),
      ...(canAdd ? [{ kind: 'add' as const, id: 'add' as const }] : []),
    ],
    actionNotes: count >= 2 ? ACTION_NOTES : [],
    footnoteKeys: ['pages.relayDetail.keyAppliesNow', 'pages.relayDetail.keysFootnote'],
    rows: rows.map((row, index) => {
      const fetching = fetchingKeyIDs.has(row.id);
      const status = fetching ? undefined : entries[index]?.status;
      const actions: RelayKeyAction[] = [
        // Open the model library filtered by key(id): not shown when the catalog is 0; present for a single key too.
        ...(row.catalogCount > 0 ? ['viewModels' as const] : []),
        ...(implicit
          ? ['replace' as const]
          : [
              ...(count >= 2 ? ['rename' as const] : []),
              'replace' as const,
              ...(index > 0 ? ['moveUp' as const] : []),
              ...(index < count - 1 ? ['moveDown' as const] : []),
              ...(!row.isPrimary ? ['delete' as const] : []),
            ]),
      ];
      return {
        id: row.id,
        title: relayKeyTitle(row),
        preview: row.preview,
        primaryBadge: row.isPrimary && count >= 2,
        statusKey: fetching ? 'pages.relayDetail.keyStatusLoading' : relayKeyStatusKey(row.status),
        statusMark: fetching ? 'progress' : relayKeyStatusMark(row.status),
        catalog: relayKeyCatalogText(row.catalogCount),
        catalogCount: row.catalogCount,
        enabledUsing: row.enabledCount > 0
          ? { key: 'pages.relayDetail.keyEnabledUsing', values: { count: row.enabledCount } }
          : { key: 'pages.relayDetail.keyEnabledNone' },
        ...(status && knownRelayKeyStatusState(status.state) && status.state !== 'ok' && status.httpStatus !== undefined
          ? {
              lastStatus: {
                httpStatus: status.httpStatus,
                statusKey: relayKeyStatusKey(status.state),
                ...(status.checkedAt ? { checkedAt: status.checkedAt } : {}),
              },
            }
          : {}),
        deleteBlocked: row.isPrimary && count >= 2,
        panelNoteKey: row.isPrimary && count >= 2 ? 'pages.relayDetail.keyPrimaryNotDeletable' : null,
        actions,
        usingModelIDs: provider.models
          .filter((model) => relayEffectiveKeyID(provider, model.id) === row.id)
          .map((model) => model.id),
      };
    }),
  };
}

/* ── Input dialogs (BOARD-KEYS-13): the container reuses Dialog, only title / field / placeholder / note are defined here ── */

export type RelayKeyInputKind = 'add' | 'replace' | 'rename';

export interface RelayKeyInputField {
  id: 'name' | 'secret';
  titleKey: string;
  /** The placeholder differs from the field title; the rename placeholder is this key's mask. */
  placeholder: KeyText | { literal: string } | null;
}

export interface RelayKeyInputSheet {
  titleKey: string;
  fields: RelayKeyInputField[];
  noteKey: string | null;
}

const SECRET_FIELD: RelayKeyInputField = {
  id: 'secret',
  titleKey: 'pages.relayDetail.keyFieldApiKey',
  placeholder: { key: 'pages.relaySetup.apiKeyPlaceholder' },
};

export function relayKeyInputSheet(
  kind: RelayKeyInputKind,
  row?: Pick<RelayKeysPageRow, 'preview'>,
): RelayKeyInputSheet {
  switch (kind) {
    case 'add':
      return {
        titleKey: 'pages.relayDetail.keysAdd',
        fields: [{ id: 'name', titleKey: 'pages.relaySetup.twoStep.keyName', placeholder: null }, SECRET_FIELD],
        noteKey: null,
      };
    case 'replace':
      return { titleKey: 'pages.relayDetail.keyReplace', fields: [SECRET_FIELD], noteKey: 'pages.relayDetail.keyReplaceHint' };
    case 'rename':
      return {
        titleKey: 'pages.providerDetail.renameProviderTitle',
        fields: [{ id: 'name', titleKey: 'pages.relaySetup.twoStep.keyName', placeholder: { literal: row?.preview ?? '' } }],
        noteKey: 'pages.relayDetail.keyRenameHint',
      };
  }
}

/* ── Hints after operations (BOARD-KEYS-12 / 17): the status written back for that key after a read-only operation ends, with no separate probe ── */

export type RelayKeyWarning = 'fetchFailed' | 'rejected' | 'fetchInterrupted';
/** Add succeeded: listed = N entries listed by this key, new = M entries listed only by this key. */
export interface RelayKeyAddedNotice {
  kind: 'added';
  keyID: string;
  listed: number;
  new: number;
}
export type RelayKeyNotice = RelayKeyWarning | RelayKeyAddedNotice;

export const RELAY_KEY_NOTICE_TEXT: Record<RelayKeyWarning, string> = {
  fetchFailed: 'pages.relayDetail.keyNoticeFetchFailed',
  rejected: 'pages.relayDetail.keyNoticeRejected',
  fetchInterrupted: 'pages.relayDetail.keyNoticeFetchInterrupted',
};

export interface RelayKeyNoticeView {
  tone: 'success' | 'warning';
  /** Joined in order with " · " (the separator is not part of the copy). */
  parts: KeyText[];
  /** Trailing link: open the model library by key(id). */
  link: { key: string; keyID: string } | null;
}

export function relayKeyNoticeView(notice: RelayKeyNotice): RelayKeyNoticeView {
  if (typeof notice === 'string') {
    return { tone: 'warning', parts: [{ key: RELAY_KEY_NOTICE_TEXT[notice] }], link: null };
  }
  return {
    tone: 'success',
    parts: [
      { key: 'pages.relayDetail.keyNoticeAdded', values: { count: notice.listed } },
      ...(notice.new > 0 ? [{ key: 'pages.relayDetail.keyNoticeAddedNew', values: { count: notice.new } }] : []),
    ],
    link: { key: 'pages.relayDetail.keyNoticeViewModels', keyID: notice.keyID },
  };
}

/** Same-sentence criterion used for hint dedupe. */
export function sameRelayKeyNotice(a: RelayKeyNotice, b: RelayKeyNotice): boolean {
  if (typeof a === 'string' || typeof b === 'string') return a === b;
  return a.keyID === b.keyID && a.listed === b.listed && a.new === b.new;
}

/** Which key the catalog-fetching operation fetches: only add / replaceSecret. */
export function relayKeyOpFetchedKeyID(op: RelayKeyOp): string | null {
  return op.type === 'add' || op.type === 'replaceSecret' ? op.id : null;
}

/** N entries listed by this key and M entries listed only by it; the listing criterion is the same source as the catalog count (listingKeysOf). */
function relayKeyListingCounts(provider: Provider, keyID: string): { listed: number; new: number } {
  const ids = relayKeyIDs(provider);
  let listed = 0;
  let only = 0;
  for (const entry of provider.catalogModels) {
    const listers = listingKeysOf(ids, entry);
    if (!listers.includes(keyID)) continue;
    listed += 1;
    if (listers.length === 1) only += 1;
  }
  return { listed, new: only };
}

/**
 * "Accepted" = the key change has been persisted. After acceptance, look at the fetched key's current status: empty = the write-back was overridden by another change (cleared when persisting);
 * on ok only an add where this key lists N > 0 gives added (replace gives no hint); otherwise = fetch failed; if that key no longer exists (deleted) there is no hint.
 * Warning and added are given by this one function, so they are naturally mutually exclusive.
 */
export function relayKeyNotice(provider: Provider, op: RelayKeyOp, accepted: boolean): RelayKeyNotice | null {
  if (!accepted) return 'rejected';
  const keyID = relayKeyOpFetchedKeyID(op);
  if (!keyID) return null;
  const entry = relayKeyList(provider).find((key) => key.id === keyID);
  if (!entry) return null;
  const state = entry.status?.state;
  if (!state) return 'fetchInterrupted';
  if (state !== 'ok') return 'fetchFailed';
  if (op.type !== 'add') return null;
  const counts = relayKeyListingCounts(provider, keyID);
  return counts.listed > 0 ? { kind: 'added', keyID, ...counts } : null;
}
