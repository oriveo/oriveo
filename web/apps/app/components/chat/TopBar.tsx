'use client';

import { memo, type ReactNode } from 'react';
import type { ProviderKind, RelayKind } from '@oriveo/shared';
import { useTranslations } from 'next-intl';
import { MenuIcon } from '../icons';
import { ModelTrigger } from './ModelTrigger';
import { MemoryPopover } from './MemoryPopover';
import styles from './TopBar.module.css';

interface TopBarProps {
  /** Fully transparent in the empty state so the aurora glow reaches the top; with messages, a gradient scrim that is opaque at the top and fades downwards covers the scrolling content */
  transparentChrome?: boolean;
  modelName?: string;
  providerKind?: ProviderKind;
  /**
   * Protocol type selected for a Relay provider, which decides whose logo the icon shows:
   * openai_compatible / codex_style -> OpenAI; anthropic_compatible -> Anthropic;
   * gemini_compatible -> Gemini; custom or unset -> the Relay logo.
   */
  relayKind?: RelayKind;
  sidebarOpen?: boolean;
  onToggleSidebar?: () => void;
  onModelClick?: () => void;
  /** Rendered inside the bar so absolute positioning anchors correctly */
  modelSwitcher?: ReactNode;
  /** Extra action buttons rendered on the trailing side */
  extraActions?: ReactNode;
  /** Memory props */
  memoryText?: string;
  useMemory?: boolean;
  onToggleMemory?: () => void;
  /** Skill indicator */
  skillIcon?: string;
  skillName?: string;
  /** Streaming indicator */
  isStreaming?: boolean;
  /** Conversation cost */
  conversationCost?: number;
}

export const TopBar = memo(function TopBar({ transparentChrome, modelName, providerKind, relayKind, sidebarOpen, onToggleSidebar, onModelClick, modelSwitcher, extraActions, memoryText, useMemory, onToggleMemory, skillIcon, skillName, isStreaming, conversationCost }: TopBarProps) {
  const tSidebar = useTranslations('sidebar');

  return (
    <div className={styles.bar} data-topbar data-transparent={transparentChrome ? 'true' : undefined}>
      <button
        type="button"
        className={styles.sidebarToggle}
        data-sidebar-closed={!sidebarOpen}
        onClick={onToggleSidebar}
        aria-label={tSidebar('toggleSidebar')}
        title={tSidebar('toggleSidebar')}
      >
        <MenuIcon />
      </button>

      <div className={styles.modelInfo}>
        {skillIcon && skillName && (
          <span className={styles.skillChip}>
            <span className={styles.skillChipBadge} aria-hidden="true">
              <span className={styles.skillChipBadgeHalo} />
              <span className={styles.skillChipBadgeIcon}>{skillIcon}</span>
            </span>
            <span className={styles.skillChipName}>{skillName}</span>
          </span>
        )}
        <ModelTrigger
          modelName={modelName}
          providerKind={providerKind}
          relayKind={relayKind}
          onModelClick={onModelClick}
        />

        <MemoryPopover memoryText={memoryText} useMemory={useMemory} onToggleMemory={onToggleMemory} />
      </div>

      {!!conversationCost && conversationCost > 0 && !isStreaming && (
        <span className={styles.costPill}>
          {conversationCost < 0.01
            ? `$${conversationCost.toFixed(4)}`
            : `$${conversationCost.toFixed(2)}`}
        </span>
      )}

      {extraActions}

      {modelSwitcher}
    </div>
  );
});
