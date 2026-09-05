'use client';

import { useMemo, useState, useCallback, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type { Skill } from '@oriveo/shared';
import { useAppStore } from '../../providers/StoreProvider';
import { getVanillaStore } from '../../providers/StoreProvider';
import {
  getCatalogByCategory,
  deleteSkillOp,
  forkSkillOp,
  updateSkillOp,
  togglePinOp,
} from '../../lib/core/skills/ops';
import { startConversationWithSkill } from '../../lib/core/skills/start-conversation';
import { useSkillL10n } from '../../lib/hooks/useSkillL10n';
import { showToast } from '../../components/Toast';
import { SkillIcon } from '../../components/skills/SkillIcon';
import { SkillActionPromptDialog } from '../../components/skills/SkillActionPromptDialog';
import styles from './SkillsPage.module.css';

const ALL_CATEGORY = '__all__';

type SkillPromptKind = 'provider';

export function SkillsPage() {
  const t = useTranslations('skills');
  const tBuiltin = useTranslations('builtinSkills');
  const { localizedName, localizedDescription, localizedCategoryName } = useSkillL10n();
  const router = useRouter();

  const catalogSkills = useAppStore((s) => s.catalogSkills);
  const userSkills = useAppStore((s) => s.userSkills);
  const skillCategories = useAppStore((s) => s.skillCategories);

  const catalogByCategory = useMemo(
    () => getCatalogByCategory(getVanillaStore()),
    [catalogSkills, skillCategories],
  );
  const categoryMetaById = useMemo(
    () => new Map(skillCategories.map((category) => [category.id, category])),
    [skillCategories],
  );

  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [loadingId, setLoadingId] = useState<string | null>(null);
  const [activeCategory, setActiveCategory] = useState(ALL_CATEGORY);
  const [promptKind, setPromptKind] = useState<SkillPromptKind | null>(null);

  //   catalog  
  useEffect(() => {
    if (activeCategory !== ALL_CATEGORY && !catalogByCategory.has(activeCategory)) {
      setActiveCategory(ALL_CATEGORY);
    }
  }, [catalogByCategory, activeCategory]);

  //   catalog skills
  const filteredCatalogSkills = useMemo(() => {
    if (activeCategory === ALL_CATEGORY) {
      return Array.from(catalogByCategory.values()).flat();
    }
    return catalogByCategory.get(activeCategory) ?? [];
  }, [catalogByCategory, activeCategory]);

  const handleUseSkill = useCallback((skill: Skill) => {
    const store = getVanillaStore();
    const result = startConversationWithSkill(store, skill, {
      title: localizedName(skill),
    });
    if (result.kind === 'no-provider') {
      showToast(t('needProvider'));
      setPromptKind('provider');
      return;
    }
    router.push(`/chat/${result.conversationId}`);
  }, [router, t, localizedName]);

  const handleTogglePin = useCallback(async (skill: Skill) => {
    const store = getVanillaStore();
    setLoadingId(skill.id);
    try {
      const allSkills = [...(store.getState().catalogSkills ?? []), ...userSkills];
      const currentPinned = allSkills.filter((s) => s.isPinned);
      const nextPinOrder = skill.isPinned ? 0 : currentPinned.length;
      await togglePinOp(store, skill, nextPinOrder);
    } catch (error) {
      showToast(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingId(null);
    }
  }, [userSkills, t]);

  const handleFork = useCallback(async (skill: Skill) => {
    const store = getVanillaStore();
    setLoadingId(skill.id);
    try {
      const forked = await forkSkillOp(store, skill.id);
      router.push(`/skills/edit?id=${forked.id}`);
    } catch (error) {
      showToast(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingId(null);
    }
  }, [router]);

  const handleDelete = useCallback(async (skill: Skill) => {
    const store = getVanillaStore();
    setLoadingId(skill.id);
    try {
      const knowledgeBase = skill.knowledgeBase;
      const requiresKnowledgeCleanup = Boolean(
        knowledgeBase
        && (
          knowledgeBase.vectorStoreId.trim().length > 0
          || knowledgeBase.files.some((file) => file.openAIFileId?.trim())
        ),
      );
      const openAIProvider = requiresKnowledgeCleanup
        ? (store.getState().providers ?? []).find((provider) => (
          provider.kind === 'openAI' && provider.apiKey.trim().length > 0
        ))
        : null;

      if (requiresKnowledgeCleanup && !openAIProvider) {
        showToast(t('openai_not_configured'));
        return;
      }

      await deleteSkillOp(store, skill.id, openAIProvider ? {
        apiKey: openAIProvider.apiKey,
        baseURL: openAIProvider.baseURLText,
      } : undefined);
    } catch (error) {
      showToast(error instanceof Error ? error.message : String(error));
    } finally {
      setLoadingId(null);
      setDeletingId(null);
    }
  }, [t]);

  const isLoading = !catalogSkills || catalogSkills.length === 0;

  return (
    <div className={styles.page}>
      <SkillActionPromptDialog
        open={promptKind !== null}
        kind={promptKind ?? 'provider'}
        title={t('providerRequiredTitle')}
        message={t('providerRequiredMessage')}
        actionLabel={t('providerRequiredAction')}
        cancelLabel={t('promptCancel')}
        onClose={() => setPromptKind(null)}
        onAction={() => {
          setPromptKind(null);
          router.push('/providers/new');
        }}
      />
      <div className={styles.header}>
        <h1 className={styles.title}>{t('title')}</h1>
        <button
          type="button"
          className={styles.newBtn}
          onClick={() => {
            router.push('/skills/edit');
          }}
        >
          + {t('newSkill')}
        </button>
      </div>

      {/* My Skills */}
      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('mySkills')}</h2>
        {userSkills && userSkills.length > 0 ? (
          <div className={styles.grid}>
            {userSkills.map((skill, i) => (
              <SkillCard
                key={skill.id}
                skill={skill}
                index={i}
                isUser
                isLoading={loadingId === skill.id}
                isDeleteConfirm={deletingId === skill.id}
                onUse={() => handleUseSkill(skill)}
                onEdit={() => router.push(`/skills/edit?id=${skill.id}`)}
                onTogglePin={() => handleTogglePin(skill)}
                onDeleteRequest={() => setDeletingId(skill.id)}
                onDeleteConfirm={() => handleDelete(skill)}
                onDeleteCancel={() => setDeletingId(null)}
                t={t}
                localizedName={localizedName}
                localizedDescription={localizedDescription}
              />
            ))}
          </div>
        ) : (
          <div className={styles.emptyState}>
            <div className={styles.emptyIconWrap} aria-hidden>
              {/* Heroicons sparkles */}
              <svg viewBox="0 0 24 24" fill="currentColor">
                <path
                  fillRule="evenodd"
                  d="M9 4.5a.75.75 0 0 1 .75.75v2.5h2.5a.75.75 0 0 1 0 1.5h-2.5v2.5a.75.75 0 0 1-1.5 0v-2.5h-2.5a.75.75 0 0 1 0-1.5h2.5v-2.5A.75.75 0 0 1 9 4.5Zm9 4.5a.75.75 0 0 1 .75.75v1.5h1.5a.75.75 0 0 1 0 1.5h-1.5v1.5a.75.75 0 0 1-1.5 0v-1.5h-1.5a.75.75 0 0 1 0-1.5h1.5v-1.5A.75.75 0 0 1 18 9Zm-3 7a.75.75 0 0 1 .75.75v1.5h1.5a.75.75 0 0 1 0 1.5h-1.5v1.5a.75.75 0 0 1-1.5 0v-1.5h-1.5a.75.75 0 0 1 0-1.5h1.5v-1.5A.75.75 0 0 1 15 16Z"
                  clipRule="evenodd"
                />
              </svg>
            </div>
            <p className={styles.emptyText}>{t('noCustomSkills')}</p>
            <button
              type="button"
              className={styles.emptyBtn}
              onClick={() => {
                router.push('/skills/edit');
              }}
            >
              <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden>
                <path
                  fillRule="evenodd"
                  d="M12 4.5a.75.75 0 0 1 .75.75v6h6a.75.75 0 0 1 0 1.5h-6v6a.75.75 0 0 1-1.5 0v-6h-6a.75.75 0 0 1 0-1.5h6v-6A.75.75 0 0 1 12 4.5Z"
                  clipRule="evenodd"
                />
              </svg>
              {t('createFirst')}
            </button>
          </div>
        )}
      </section>

      {/* Category filter pills + Catalog grid */}
      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('builtinSkills')}</h2>

        {!isLoading && catalogByCategory.size > 1 && (
          <div className={styles.filterBarWrap}>
            <div className={styles.filterBar}>
              <button
                type="button"
                className={`${styles.filterPill} ${activeCategory === ALL_CATEGORY ? styles.filterPillActive : ''}`}
                onClick={() => setActiveCategory(ALL_CATEGORY)}
              >
                {tBuiltin('category.all')}
                <span className={styles.filterPillCount}>
                  {Array.from(catalogByCategory.values()).reduce((sum, list) => sum + list.length, 0)}
                </span>
              </button>
              {Array.from(catalogByCategory.entries()).map(([categoryId, skills]) => {
                const meta = categoryMetaById.get(categoryId);
                return (
                  <button
                    key={categoryId}
                    type="button"
                    className={`${styles.filterPill} ${activeCategory === categoryId ? styles.filterPillActive : ''}`}
                    onClick={() => setActiveCategory(categoryId)}
                  >
                    {meta?.icon && (
                      <SkillIcon
                        icon={meta.icon}
                        size={14}
                        className={styles.filterPillEmoji}
                      />
                    )}
                    {meta ? localizedCategoryName(meta) : categoryId}
                    <span className={styles.filterPillCount}>{skills.length}</span>
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {isLoading ? (
          <div className={styles.grid}>
            {[1, 2, 3, 4, 5, 6].map((i) => (
              <div key={i} className={styles.cardSkeleton} />
            ))}
          </div>
        ) : (
          <div className={styles.grid}>
            {filteredCatalogSkills.map((skill, i) => (
              <SkillCard
                key={skill.id}
                skill={skill}
                index={i}
                isUser={false}
                isLoading={loadingId === skill.id}
                isDeleteConfirm={false}
                onUse={() => handleUseSkill(skill)}
                onEdit={() => {}}
                onTogglePin={() => {}}
                onFork={() => handleFork(skill)}
                onDeleteRequest={() => {}}
                onDeleteConfirm={() => {}}
                onDeleteCancel={() => {}}
                t={t}
                localizedName={localizedName}
                localizedDescription={localizedDescription}
              />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

interface SkillCardProps {
  skill: Skill;
  index: number;
  isUser: boolean;
  isLoading: boolean;
  isDeleteConfirm: boolean;
  onUse: () => void;
  onEdit: () => void;
  onTogglePin: () => void;
  onFork?: () => void;
  onDeleteRequest: () => void;
  onDeleteConfirm: () => void;
  onDeleteCancel: () => void;
  t: ReturnType<typeof useTranslations<'skills'>>;
  localizedName: (skill: Skill) => string;
  localizedDescription: (skill: Skill) => string;
}

function SkillCard({
  skill,
  index,
  isUser,
  isLoading,
  isDeleteConfirm,
  onUse,
  onEdit,
  onTogglePin,
  onFork,
  onDeleteRequest,
  onDeleteConfirm,
  onDeleteCancel,
  t,
  localizedName,
  localizedDescription,
}: SkillCardProps) {
  const cssVars = {
    '--skill-color': skill.color,
    '--i': index,
  } as React.CSSProperties;

  if (isDeleteConfirm) {
    return (
      <div className={styles.card} style={cssVars}>
        <p className={styles.deleteConfirmText}>
          {t('deleteConfirmTitle', { name: localizedName(skill) })}
        </p>
        <p className={styles.deleteConfirmSub}>{t('deleteConfirmMessage')}</p>
        <div className={styles.deleteConfirmActions}>
          <button type="button" className={styles.deleteDangerBtn} onClick={onDeleteConfirm}>
            {t('deleteSkill')}
          </button>
          <button type="button" className={styles.cancelBtn} onClick={onDeleteCancel}>
            {t('continueEditing')}
          </button>
        </div>
      </div>
    );
  }

  return (
    <div
      className={`${styles.card} ${isLoading ? styles.cardLoading : ''}`}
      style={cssVars}
    >
      <div className={styles.cardTop}>
        <div className={styles.cardIconWrap}>
          <SkillIcon
            icon={skill.icon}
            color="var(--skill-color)"
            size={28}
            className={styles.cardIcon}
          />
        </div>
        {skill.isPinned && (
          <span className={styles.pinnedBadge} title={t('pinned')} aria-label={t('pinned')}>
            <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden>
              <path d="M16 3.5a.75.75 0 0 1 .53.22l3.75 3.75a.75.75 0 0 1-.53 1.28h-1.18l-1.5 5.62a.75.75 0 0 1-.73.56h-3.59v4.32l-2 .96-2-.96v-4.32H4.66a.75.75 0 0 1-.73-.56l-1.5-5.62H1.25a.75.75 0 0 1-.53-1.28l3.75-3.75a.75.75 0 0 1 1.06 1.06L3.06 7h17.88l-2.47-2.47A.75.75 0 0 1 16 3.5Z" />
            </svg>
          </span>
        )}
      </div>
      <div className={styles.cardName}>{localizedName(skill)}</div>
      {skill.description && (
        <div className={styles.cardDesc}>{localizedDescription(skill)}</div>
      )}
      <div className={styles.cardActions}>
        <button type="button" className={styles.useBtn} onClick={onUse}>
          {t('useSkill')}
          <svg className={styles.useBtnArrow} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <path d="M5 12h14M13 6l6 6-6 6" />
          </svg>
        </button>
        {isUser ? (
          <>
            <button type="button" className={styles.iconBtn} onClick={onEdit} title={t('editSkill')} aria-label={t('editSkill')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="M16.5 3.5a2.121 2.121 0 1 1 3 3L7 19l-4 1 1-4 12.5-12.5Z" />
              </svg>
            </button>
            <button
              type="button"
              className={styles.iconBtn}
              onClick={onTogglePin}
              title={skill.isPinned ? t('unpinFromHome') : t('pinToHome')}
              aria-label={skill.isPinned ? t('unpinFromHome') : t('pinToHome')}
            >
              <svg viewBox="0 0 24 24" fill={skill.isPinned ? 'currentColor' : 'none'} stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="M12 17.5V22M9 4l1 5-3 3h10l-3-3 1-5" />
              </svg>
            </button>
            <button type="button" className={styles.iconBtn} onClick={onDeleteRequest} title={t('deleteSkill')} aria-label={t('deleteSkill')}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M10 11v6M14 11v6" />
              </svg>
            </button>
          </>
        ) : (
          onFork && (
            <button type="button" className={styles.forkBtn} onClick={onFork}>
              {t('forkSkill')}
            </button>
          )
        )}
      </div>
    </div>
  );
}
