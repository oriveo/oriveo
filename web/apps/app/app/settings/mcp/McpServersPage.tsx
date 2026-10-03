'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { Check, ChevronRight, Plus } from 'lucide-react';
import { BackButton, Button } from '@oriveo/ui';
import {
  outboundToolSnapshots,
  type McpConnectionState,
  type McpServerRecord,
  type McpToolChange,
  type McpToolPermission,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import { ConfirmDialog } from '../../../components/dialogs/ConfirmDialog';
import { McpAddServerDialog } from '../../../components/mcp/McpAddServerDialog';
import { McpReauthDialog } from '../../../components/mcp/McpReauthDialog';
import { McpServerIcon } from '../../../components/mcp/McpServerIcon';
import { McpToolPermissionDialog } from '../../../components/mcp/McpToolPermissionDialog';
import { McpToolsChangedDialog } from '../../../components/mcp/McpToolsChangedDialog';
import { useMcpServerPause } from '../../../components/mcp/use-mcp-server-pause';
import styles from '../../../components/mcp/Mcp.module.css';
import { mcpDisplayAddress } from '../../../lib/core/mcp/mcp-presentation';
import { mcpServerHasCredentials, probeMcpServer, refreshMcpServerTools } from '../../../lib/core/mcp/mcp-server-actions';
import { useMcpStore } from '../../../lib/core/mcp/mcp-store';
import { reportMcpServerRemoved, reportMcpToolsChanged } from '../../../lib/core/mcp/mcp-telemetry';
import { useMcpRuntimeConfig } from '../../../lib/core/mcp/use-mcp-runtime-config';

const PERMISSIONS: McpToolPermission[] = ['auto', 'ask', 'off'];
const PERMISSION_KEYS: Record<McpToolPermission, 'permission.auto' | 'permission.ask' | 'permission.off'> = {
  auto: 'permission.auto',
  ask: 'permission.ask',
  off: 'permission.off',
};
/** How many tools each group shows by default; the rest are collapsed. */
const VISIBLE_TOOLS = 3;

type ServerStatus = 'connected' | 'needsAuth' | 'unreachable' | 'needsReview';

function serverStatus(connection: McpConnectionState | undefined, snapshots: readonly McpToolSnapshot[]): ServerStatus {
  if (connection?.status === 'needsAuth') return 'needsAuth';
  if (connection?.status === 'unreachable') return 'unreachable';
  if (snapshots.some((snapshot) => snapshot.pendingReview)) return 'needsReview';
  return 'connected';
}

const STATUS_TONE: Record<ServerStatus, 'success' | 'warning' | 'danger'> = {
  connected: 'success',
  needsAuth: 'warning',
  unreachable: 'danger',
  needsReview: 'warning',
};

const STATUS_KEY: Record<ServerStatus, 'settings.statusConnected' | 'settings.statusAuthExpired' | 'settings.statusUnreachable' | 'settings.statusNeedsReview'> = {
  connected: 'settings.statusConnected',
  needsAuth: 'settings.statusAuthExpired',
  unreachable: 'settings.statusUnreachable',
  needsReview: 'settings.statusNeedsReview',
};

/**
 * MCP server management in settings. Wide screens show the list on the left and the detail on the
 * right; narrow screens fall back to a single column: the list when nothing is selected, the detail
 * once something is, with an entry at the top to return to the list.
 */
export function McpServersPage() {
  const t = useTranslations('mcp');
  const locale = useLocale();
  const router = useRouter();
  const searchParams = useSearchParams();
  const runtimeConfig = useMcpRuntimeConfig();
  const hydrated = useMcpStore((state) => state.hydrated);
  const servers = useMcpStore((state) => state.servers);
  const snapshots = useMcpStore((state) => state.snapshots);
  const permissions = useMcpStore((state) => state.permissions);
  const connections = useMcpStore((state) => state.connections);
  const setToolPermission = useMcpStore((state) => state.setToolPermission);
  const removeServer = useMcpStore((state) => state.removeServer);
  const pauseServer = useMcpServerPause();

  const [selectedId, setSelectedId] = useState<string | null>(searchParams.get('server'));
  const [addOpen, setAddOpen] = useState(searchParams.get('add') === '1');
  const [reauthId, setReauthId] = useState<string | null>(null);
  const [review, setReview] = useState<{ serverId: string; previous?: McpToolSnapshot[]; removed?: McpToolChange[] } | null>(null);
  const [removeTarget, setRemoveTarget] = useState<McpServerRecord | null>(null);
  const [removing, setRemoving] = useState(false);
  const [removeFailed, setRemoveFailed] = useState(false);
  const [permissionTool, setPermissionTool] = useState<string | null>(null);
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({});
  const [busy, setBusy] = useState<'reload' | 'probe' | null>(null);
  const [reloadNotice, setReloadNotice] = useState(false);
  const [hasCredentials, setHasCredentials] = useState<boolean | null>(null);

  // With the feature switch off (read from the model catalog) this page does not exist: the entry is
  // hidden anyway, and anyone arriving directly is sent back to settings.
  useEffect(() => {
    if (!runtimeConfig.enabled) router.replace('/settings');
  }, [router, runtimeConfig.enabled]);

  // On wide screens the right side always shows a server: the first one when nothing is explicitly
  // selected. Narrow screens use `selectedId` to decide between list and detail.
  const selected = useMemo(
    () => servers.find((server) => server.id === selectedId) ?? null,
    [selectedId, servers],
  );
  const shown = selected ?? servers[0] ?? null;
  const shownId = shown?.id ?? null;

  useEffect(() => {
    setPermissionTool(null);
    setReloadNotice(false);
  }, [shownId]);

  // The "sign-in method" row needs to know whether a credential is stored on this device; re-read it
  // when the connection status changes (re-authorization, token exchange).
  useEffect(() => {
    setHasCredentials(null);
    if (!shownId) return;
    let cancelled = false;
    void mcpServerHasCredentials(shownId).then((value) => {
      if (!cancelled) setHasCredentials(value);
    });
    return () => {
      cancelled = true;
    };
  }, [shownId, connections]);

  const reloadTools = useCallback(async (server: McpServerRecord) => {
    setBusy('reload');
    setReloadNotice(false);
    const previous = [...(useMcpStore.getState().snapshots[server.id] ?? [])];
    const result = await refreshMcpServerTools(server.id);
    setBusy(null);
    if (result.status === 'connected') {
      reportMcpToolsChanged(result.changes);
      const removed = result.changes.filter((change) => change.kind === 'removed');
      const pending = (useMcpStore.getState().snapshots[server.id] ?? []).some((snapshot) => snapshot.pendingReview);
      if (pending || removed.length > 0) setReview({ serverId: server.id, previous, removed });
    } else if (result.status === 'unreachable') {
      setReloadNotice(true);
    }
  }, []);

  const probeAll = useCallback(async () => {
    setBusy('probe');
    await Promise.all(useMcpStore.getState().servers.map((server) => probeMcpServer(server.id).catch(() => undefined)));
    setBusy(null);
  }, []);

  const confirmRemove = async () => {
    if (!removeTarget) return;
    setRemoving(true);
    setRemoveFailed(false);
    try {
      await removeServer(removeTarget.id);
      reportMcpServerRemoved();
      if (selectedId === removeTarget.id) setSelectedId(null);
      setRemoveTarget(null);
    } catch {
      // If the credential could not be deleted the record is left as is (credential first, then the
      // record), so it can be retried.
      setRemoveFailed(true);
    } finally {
      setRemoving(false);
    }
  };

  if (!runtimeConfig.enabled) return null;

  const renderDetail = (server: McpServerRecord) => {
    const tools = [...(snapshots[server.id] ?? [])].sort((a, b) => a.title.localeCompare(b.title, locale));
    const serverPermissions = permissions[server.id] ?? {};
    const connection = connections[server.id];
    const status = serverStatus(connection, tools);
    const unavailable = status === 'needsAuth';
    const usable = outboundToolSnapshots(tools, serverPermissions).length;
    const groups: Array<{ key: 'readOnly' | 'changes'; title: string; tools: McpToolSnapshot[] }> = [
      { key: 'readOnly', title: t('settings.readOnly'), tools: tools.filter((tool) => tool.readOnly) },
      { key: 'changes', title: t('settings.changesData'), tools: tools.filter((tool) => !tool.readOnly) },
    ];
    const activeTool = tools.find((tool) => tool.toolName === permissionTool) ?? null;
    const permissionOf = (tool: McpToolSnapshot): McpToolPermission => serverPermissions[tool.toolName] ?? (tool.readOnly ? 'auto' : 'ask');
    const signInLabel =
      server.authKind === 'token'
        ? t('settings.signInToken')
        : hasCredentials === false
          ? t('settings.signInNone')
          : t('settings.signInBrowser');

    return (
      <section aria-label={server.name} data-mcp-detail={server.id} data-status={status}>
        <BackButton className={styles.detailBack} label={t('settings.backToList')} onClick={() => setSelectedId(null)} />
        <div className={styles.heroCard}>
          <div className={styles.heroRow}>
            <McpServerIcon name={server.name} iconURL={server.iconURL} size={52} />
            <div className={styles.heroText}>
              <span className={styles.heroName}>{server.name}</span>
              <span className={styles.heroMeta}>
                <span className={styles.statusPill} data-tone={STATUS_TONE[status]}>{t(STATUS_KEY[status])}</span>
                <span>{unavailable ? t('settings.toolsUnavailable') : t('settings.toolCount', { count: usable })}</span>
              </span>
            </div>
          </div>
          <dl className={`${styles.kvCard} ${styles.heroKv}`} style={{ border: 0, padding: 0, background: 'transparent' }}>
            <div className={styles.kvRow}>
              <dt>{t('settings.address')}</dt>
              <dd className={styles.kvMono}>{mcpDisplayAddress(server.url)}</dd>
            </div>
            <div className={styles.kvRow}>
              <dt>{t('settings.signIn')}</dt>
              <dd>{signInLabel}</dd>
            </div>
            <div className={styles.kvRow}>
              <dt>{t('settings.lastConnected')}</dt>
              <dd>
                {connection?.lastSuccessAt
                  ? new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(connection.lastSuccessAt))
                  : t('settings.never')}
              </dd>
            </div>
          </dl>
          <div className={styles.heroActions}>
            {status === 'needsAuth' ? (
              <Button data-mcp-primary data-mcp-action="reauth" onClick={() => setReauthId(server.id)}>{t('settings.reauthorize')}</Button>
            ) : (
              <button type="button" className={styles.outlineButton} data-mcp-action="reload" disabled={busy !== null} onClick={() => void reloadTools(server)}>
                {busy === 'reload' ? t('settings.reloading') : t('settings.reloadTools')}
              </button>
            )}
            {status === 'needsReview' ? (
              <button type="button" className={styles.softPrimaryButton} data-mcp-action="review" onClick={() => setReview({ serverId: server.id })}>
                {t('settings.reviewChanges')}
              </button>
            ) : null}
          </div>
          {reloadNotice ? <p className={styles.inlineNotice} role="alert">{t('settings.reloadUnreachable')}</p> : null}
        </div>

        {tools.length === 0 ? (
          <p className={styles.noticeBlock} data-tone="neutral">{t('settings.noTools')}</p>
        ) : (
          <div className={styles.toolGroups} data-dimmed={unavailable || undefined}>
            {groups.filter((group) => group.tools.length > 0).map((group) => {
              const groupKey = `${server.id}:${group.key}`;
              const expanded = expandedGroups[groupKey] === true;
              const visible = expanded ? group.tools : group.tools.slice(0, VISIBLE_TOOLS);
              const hidden = group.tools.length - visible.length;
              return (
                <div key={group.key} data-mcp-group={group.key}>
                  <div className={styles.toolGroupHead}>
                    <h3>{group.title}</h3>
                    <span>{t('settings.count', { count: group.tools.length })}</span>
                  </div>
                  <ul className={styles.toolCard}>
                    {visible.map((tool) => {
                      const permission = permissionOf(tool);
                      // A quarantined / oversized tool is not sent to the model: its permission is
                      // still visible, but changing it requires confirming the change first.
                      const locked = unavailable || tool.pendingReview || tool.oversized;
                      return (
                        <li key={tool.toolName} className={styles.toolRow} data-off={permission === 'off' || tool.pendingReview || tool.oversized || undefined}>
                          <button type="button" className={styles.toolName} disabled={unavailable} onClick={() => setPermissionTool(tool.toolName)}>
                            {tool.title}
                          </button>
                          {tool.oversized ? (
                            <span className={styles.footnote}>{t('settings.oversized')}</span>
                          ) : tool.pendingReview ? (
                            <span className={styles.footnote}>{t('settings.needsReview')}</span>
                          ) : (
                            <select
                              className={styles.select}
                              aria-label={t('settings.permissionAria', { tool: tool.title })}
                              value={permission}
                              disabled={locked}
                              onChange={(event) => void setToolPermission(server.id, tool.toolName, event.target.value as McpToolPermission).catch(() => {})}
                            >
                              {PERMISSIONS.map((option) => (
                                <option key={option} value={option}>{t(PERMISSION_KEYS[option])}</option>
                              ))}
                            </select>
                          )}
                        </li>
                      );
                    })}
                    {hidden > 0 ? (
                      <li className={styles.toolMore}>
                        <button type="button" className={styles.linkButton} onClick={() => setExpandedGroups((current) => ({ ...current, [groupKey]: true }))}>
                          {t('settings.showMore', { count: hidden })}
                        </button>
                      </li>
                    ) : null}
                  </ul>
                </div>
              );
            })}
          </div>
        )}

        <button type="button" className={styles.dangerText} data-mcp-action="remove" onClick={() => { setRemoveFailed(false); setRemoveTarget(server); }}>
          {t('settings.removeServer')}
        </button>

        {activeTool && !activeTool.pendingReview && !activeTool.oversized ? (
          <McpToolPermissionDialog
            server={server}
            tool={activeTool}
            permission={permissionOf(activeTool)}
            onChange={(next) => void setToolPermission(server.id, activeTool.toolName, next).catch(() => {})}
            onClose={() => setPermissionTool(null)}
          />
        ) : null}
      </section>
    );
  };

  const reauthServer = servers.find((server) => server.id === reauthId) ?? null;
  const reviewServer = servers.find((server) => server.id === review?.serverId) ?? null;

  return (
    <main className={styles.page}>
      <div className={styles.pageInner}>
        <BackButton className={styles.pageBack} label={t('settings.back')} onClick={() => router.push('/settings')} />

        {hydrated && servers.length === 0 ? (
          <>
            <div className={styles.pageHeader}>
              <h1 className={styles.pageTitle}>{t('settings.title')}</h1>
            </div>
            <div className={styles.emptyCard} data-mcp-state="empty">
              <h2>{t('settings.emptyTitle')}</h2>
              <p>{t('settings.emptyBody')}</p>
              <ul className={styles.promises}>
                {(['promiseCredentials', 'promiseConfirm', 'promisePerChat'] as const).map((key) => (
                  <li key={key}>
                    <Check size={16} strokeWidth={2.6} aria-hidden="true" />
                    {t(`settings.${key}`)}
                  </li>
                ))}
              </ul>
              <Button data-mcp-primary data-mcp-action="add" onClick={() => setAddOpen(true)}>{t('settings.addServer')}</Button>
            </div>
          </>
        ) : (
          <div className={styles.split} data-view={selected ? 'detail' : 'list'}>
            <div className={styles.listPane}>
              <div className={styles.pageHeader}>
                <h1 className={styles.pageTitle}>{t('settings.title')}</h1>
                <Button data-mcp-primary data-mcp-action="add" onClick={() => setAddOpen(true)}>
                  <Plus size={16} strokeWidth={2.4} aria-hidden="true" style={{ marginInlineEnd: 6, verticalAlign: -3 }} />
                  {t('settings.add')}
                </Button>
              </div>
              <div className={styles.listMeta}>
                <strong>{t('settings.added')}</strong>
                <span>{t('settings.count', { count: servers.length })}</span>
              </div>
              <ul className={styles.serverList}>
                {servers.map((server) => {
                  const tools = snapshots[server.id] ?? [];
                  const status = serverStatus(connections[server.id], tools);
                  return (
                    <li key={server.id}>
                      <button
                        type="button"
                        className={styles.serverCard}
                        aria-current={shown?.id === server.id ? 'true' : undefined}
                        data-mcp-server={server.id}
                        data-status={status}
                        onClick={() => {
                          setSelectedId(server.id);
                          // On entering the detail view, show the change confirmation first if any
                          // tool is quarantined.
                          if (status === 'needsReview') setReview({ serverId: server.id });
                        }}
                      >
                        <McpServerIcon name={server.name} iconURL={server.iconURL} size={44} />
                        <span className={styles.serverCardText}>
                          <strong>{server.name}</strong>
                          <span className={styles.serverCardMeta}>
                            <span className={styles.statusPill} data-tone={STATUS_TONE[status]}>{t(STATUS_KEY[status])}</span>
                            <span>
                              {status === 'needsAuth'
                                ? t('settings.needsReauth')
                                : status === 'needsReview'
                                  ? t('settings.needsReview')
                                  : t('settings.toolCount', { count: outboundToolSnapshots(tools, permissions[server.id] ?? {}).length })}
                            </span>
                          </span>
                        </span>
                        <ChevronRight size={16} className={styles.serverCardChevron} aria-hidden="true" />
                      </button>
                    </li>
                  );
                })}
              </ul>
              <p className={styles.pageNote}>{t('settings.trustNote')}</p>
              <button type="button" className={styles.linkButton} style={{ marginInlineStart: 4 }} disabled={busy !== null} data-mcp-action="probe" onClick={() => void probeAll()}>
                {t('settings.refresh')}
              </button>
            </div>
            <div className={styles.detailPane}>{shown ? renderDetail(shown) : null}</div>
          </div>
        )}
      </div>

      <McpAddServerDialog
        open={addOpen}
        onClose={() => setAddOpen(false)}
        onAdded={(serverId) => setSelectedId(serverId)}
      />
      <McpReauthDialog server={reauthServer} trigger="reauth" onClose={() => setReauthId(null)} />
      <McpToolsChangedDialog
        server={reviewServer}
        previous={review?.previous}
        removed={review?.removed}
        onClose={() => setReview(null)}
        onPause={(serverId) => {
          void pauseServer(serverId);
          setReview(null);
        }}
      />
      <ConfirmDialog
        open={removeTarget !== null}
        title={removeTarget ? t('remove.title', { name: removeTarget.name }) : ''}
        message={removeFailed ? `${t('remove.body')}\n\n${t('remove.failed')}` : t('remove.body')}
        confirmLabel={t('remove.confirm')}
        cancelLabel={t('remove.cancel')}
        destructive
        loading={removing}
        onConfirm={() => void confirmRemove()}
        onCancel={() => setRemoveTarget(null)}
      />
    </main>
  );
}
