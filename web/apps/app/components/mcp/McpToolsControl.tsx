'use client';

import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { Wrench } from 'lucide-react';
import { Button } from '@oriveo/ui';
import type { AIModel, Provider } from '@oriveo/shared';
import { ComposerToolButton } from '../chat/ComposerToolButton';
import { connectionSupportsMcpTools } from '../../lib/core/mcp/mcp-chat';
import { buildMcpPanelModel, type McpPanelRow } from '../../lib/core/mcp/mcp-presentation';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { useMcpRuntimeConfig } from '../../lib/core/mcp/use-mcp-runtime-config';
import { McpReauthDialog } from './McpReauthDialog';
import { McpServerIcon } from './McpServerIcon';
import { McpSwitch } from './McpSwitch';
import { McpToolsChangedDialog } from './McpToolsChangedDialog';
import { useMcpServerPause } from './use-mcp-server-pause';
import styles from './Mcp.module.css';

const EMPTY_IDS: readonly string[] = [];

function relativeTime(timestamp: number, locale: string, now: number = Date.now()): string {
  const seconds = Math.round((timestamp - now) / 1000);
  const format = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  const abs = Math.abs(seconds);
  if (abs < 3600) return format.format(Math.round(seconds / 60), 'minute');
  if (abs < 86_400) return format.format(Math.round(seconds / 3600), 'hour');
  return format.format(Math.round(seconds / 86_400), 'day');
}

/**
 * The "Tools" pill in the composer and its tools popover.
 *
 * Switches are remembered per conversation: `scope` is the conversation id, or the draft scope
 * (`mcpDraftScope`) while a new conversation has no id yet. The popover is a non-modal panel above the
 * composer, not a bottom sheet; on narrow screens it spans the full composer width.
 */
export function McpToolsControl({
  scope,
  provider,
  model,
  isStreaming,
  onOpenModelSwitcher,
}: {
  scope: string;
  provider: Provider | undefined;
  model: AIModel | undefined;
  isStreaming: boolean;
  onOpenModelSwitcher?: () => void;
}) {
  const t = useTranslations('mcp');
  const locale = useLocale();
  const router = useRouter();
  const runtimeConfig = useMcpRuntimeConfig();
  const hydrated = useMcpStore((state) => state.hydrated);
  const servers = useMcpStore((state) => state.servers);
  const snapshots = useMcpStore((state) => state.snapshots);
  const permissions = useMcpStore((state) => state.permissions);
  const connections = useMcpStore((state) => state.connections);
  const enabledIds = useMcpStore((state) => state.conversationServers[scope] ?? EMPTY_IDS);
  const setServerEnabled = useMcpStore((state) => state.setServerEnabled);
  const pauseServer = useMcpServerPause();

  const [open, setOpen] = useState(false);
  const [reauthServerId, setReauthServerId] = useState<string | null>(null);
  const [reviewServerId, setReviewServerId] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const panelId = useId();

  // The current model cannot carry client-side tools: the panel says so and the switches are disabled.
  const unsupported = useMemo(() => !connectionSupportsMcpTools(provider, model), [provider, model]);
  const panel = useMemo(
    () => buildMcpPanelModel({ servers: hydrated ? servers : [], snapshots, permissions, connections, enabledServerIds: enabledIds, runtimeConfig }),
    [connections, enabledIds, hydrated, permissions, runtimeConfig, servers, snapshots],
  );

  const close = useCallback((restoreFocus: boolean) => {
    // If focus is still inside the popover when it disappears, it falls back to body and keyboard users
    // have to start again from the top of the page, so hand it back to the pill. Closing by clicking
    // outside is unaffected: the browser then moves focus to the clicked element.
    const focusInside = panelRef.current?.contains(document.activeElement) ?? false;
    setOpen(false);
    if (restoreFocus || focusInside) triggerRef.current?.focus({ preventScroll: true });
  }, []);

  // The popover is `role="dialog"`: moving focus into it on open makes screen readers announce its name
  // and starts Tab from its first control.
  useEffect(() => {
    if (open) panelRef.current?.focus({ preventScroll: true });
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (rootRef.current?.contains(event.target as Node)) return;
      close(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close(true);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [close, open]);

  // On entering the panel, if an enabled server has quarantined tools, show the change confirmation
  // first. Never raised while a reply is in progress.
  const openPanel = () => {
    setOpen(true);
    if (isStreaming || unsupported) return;
    const pending = panel.rows.find((row) => row.enabled && row.hasPendingReview && row.status === 'ready');
    if (pending) setReviewServerId(pending.server.id);
  };

  if (!runtimeConfig.enabled) return null;

  const count = unsupported ? 0 : panel.enabledCount;
  const reauthServer = servers.find((server) => server.id === reauthServerId) ?? null;
  const reviewServer = servers.find((server) => server.id === reviewServerId) ?? null;

  const rowStatus = (row: McpPanelRow): string => {
    if (row.status === 'needsAuth') return t('chat.panel.authExpired');
    if (row.status === 'unreachable') {
      return row.lastSuccessAt
        ? t('chat.panel.unreachable', { time: relativeTime(row.lastSuccessAt, locale) })
        : t('chat.panel.unreachableNever');
    }
    if (row.hasPendingReview) return t('chat.panel.needsReview');
    return t('chat.panel.toolCount', { count: row.toolCount });
  };

  return (
    // When tools cannot be used the pill is dimmed but still opens, because opening it shows the
    // reason; that is why `disabled` is not used.
    <div ref={rootRef} className={styles.toolsControl} data-mcp-unsupported={unsupported || undefined}>
      <ComposerToolButton
        buttonRef={triggerRef}
        icon={<Wrench size={16} />}
        label={t('chat.tools')}
        count={count || undefined}
        emphasized={count > 0}
        active={open}
        ariaLabel={t('chat.toolsAria')}
        ariaDescription={count > 0 ? t('chat.toolsAriaCount', { count }) : unsupported ? t('chat.panel.unsupportedTitle') : undefined}
        ariaExpanded={open}
        ariaControls={open ? panelId : undefined}
        onClick={() => (open ? close(false) : openPanel())}
      />

      {open ? (
        <div ref={panelRef} id={panelId} className={styles.toolsPanel} role="dialog" aria-label={t('chat.panel.title')} tabIndex={-1} data-mcp-panel>
          {panel.rows.length === 0 ? (
            <div className={styles.panelEmpty} data-mcp-state="empty">
              <span className={styles.panelEmptyIcon} aria-hidden="true"><Wrench size={22} strokeWidth={1.8} /></span>
              <h3 className={styles.panelTitle}>{t('chat.panel.emptyTitle')}</h3>
              <p className={styles.panelText}>{t('chat.panel.emptyBody')}</p>
              <Button data-mcp-primary onClick={() => { close(false); router.push('/settings/mcp?add=1'); }}>
                {t('chat.panel.addServer')}
              </Button>
            </div>
          ) : (
            <>
              <div className={styles.panelHead}>
                <h3 className={styles.panelTitle}>{t('chat.panel.title')}</h3>
                {!unsupported ? <p className={styles.panelText}>{t('chat.panel.subtitle')}</p> : null}
              </div>

              {unsupported ? (
                <div className={styles.noticeBlock} data-tone="warning" data-mcp-state="unsupported">
                  <strong>{t('chat.panel.unsupportedTitle')}</strong>
                  <p>{t('chat.panel.unsupportedModel')}</p>
                  {onOpenModelSwitcher ? (
                    <button type="button" className={styles.linkButton} onClick={() => { close(false); onOpenModelSwitcher(); }}>
                      {t('chat.panel.switchModel')}
                    </button>
                  ) : null}
                </div>
              ) : null}

              <ul className={styles.panelRows} data-dimmed={unsupported ? true : undefined}>
                {panel.rows.map((row) => (
                  <li key={row.server.id} className={styles.panelRow} data-status={row.status}>
                    <McpServerIcon name={row.server.name} iconURL={row.server.iconURL} size={32} />
                    <span className={styles.panelRowText}>
                      <strong>{row.server.name}</strong>
                      <span>{rowStatus(row)}</span>
                    </span>
                    {unsupported ? (
                      <McpSwitch checked={row.enabled} disabled label={t('chat.panel.toggleAria', { server: row.server.name })} onChange={() => {}} />
                    ) : row.status === 'needsAuth' ? (
                      <button type="button" className={styles.linkButton} disabled={isStreaming} onClick={() => setReauthServerId(row.server.id)}>
                        {t('chat.panel.reauthorize')}
                      </button>
                    ) : row.hasPendingReview && row.status === 'ready' && row.enabled ? (
                      <button type="button" className={styles.linkButton} disabled={isStreaming} onClick={() => setReviewServerId(row.server.id)}>
                        {t('chat.panel.review')}
                      </button>
                    ) : (
                      <McpSwitch
                        checked={row.enabled}
                        // The switch of an unreachable server is disabled; one that is already on can still be turned off.
                        disabled={row.status === 'unreachable' && !row.enabled}
                        label={t('chat.panel.toggleAria', { server: row.server.name })}
                        onChange={(next) => {
                          void setServerEnabled(scope, row.server.id, next).catch(() => {});
                          if (next && row.hasPendingReview && !isStreaming) setReviewServerId(row.server.id);
                        }}
                      />
                    )}
                  </li>
                ))}
              </ul>

              <div className={styles.panelFoot}>
                {!unsupported && panel.truncated ? (
                  <p className={styles.panelFootText} data-tone="warning" role="status">
                    {t('chat.panel.overLimit', { max: runtimeConfig.maxToolsPerRequest })}
                  </p>
                ) : !unsupported && panel.toolCount > 0 ? (
                  <p className={styles.panelFootText}>
                    {t('chat.panel.footer', { count: panel.toolCount, tokens: panel.estimatedTokens.toLocaleString(locale) })}
                  </p>
                ) : null}
                <button type="button" className={styles.linkButton} onClick={() => { close(false); router.push('/settings/mcp'); }}>
                  {t('chat.panel.manage')}
                </button>
              </div>
            </>
          )}
        </div>
      ) : null}

      <McpReauthDialog server={reauthServer} trigger="reauth" onClose={() => setReauthServerId(null)} />
      <McpToolsChangedDialog
        server={reviewServer}
        onClose={() => setReviewServerId(null)}
        onPause={(serverId) => {
          void pauseServer(serverId);
          setReviewServerId(null);
        }}
      />
    </div>
  );
}
