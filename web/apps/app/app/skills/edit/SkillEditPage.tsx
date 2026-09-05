'use client';

import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import type {
  Skill,
  SkillKnowledgeBase,
  SkillKnowledgeBaseFile,
  SkillKnowledgeErrorCode,
  SkillKnowledgeFile,
} from '@oriveo/shared';
import { getVanillaStore } from '../../../providers/StoreProvider';
import { getSkillById, createSkillOp, updateSkillOp } from '../../../lib/core/skills/ops';
import { showToast } from '../../../components/Toast';
import {
  buildDraftKnowledgeCleanupPlan,
  buildLocalKnowledgeBaseFile,
  buildReferenceKnowledgeFile,
  formatBytes,
  isKnowledgeFileTypeSupported,
  MAX_KNOWLEDGE_FILES,
  prepareKnowledgeUpload,
  removeLocalKnowledgeBaseFile,
  requiresRemoteKnowledgeCleanup,
  sumKnowledgeBaseBytes,
  upsertLocalKnowledgeBase,
  validateKnowledgeBaseQuota,
  validateReferenceFileSize,
} from './knowledge-utils';
import { parseOfficeFile } from '../../../lib/utils/office-parser';
import styles from './SkillEditPage.module.css';

class KnowledgeApiError extends Error {
  code?: string;
  constructor(message: string) {
    super(message);
    this.code = message;
  }
}

async function fetchKnowledgeRuntimeConfig(): Promise<any> {
  return null;
}

async function checkKnowledgeEligibility(_input?: unknown): Promise<any> {
  return { eligible: false };
}

async function checkKnowledgeFileStatus(_input?: unknown): Promise<any> {
  return { status: 'disabled' };
}

async function cleanupDraftKnowledge(_input?: unknown): Promise<void> {}
async function uploadKnowledgeFile(_input?: unknown): Promise<never> {
  throw new KnowledgeApiError('knowledge_service_unavailable');
}
async function replaceKnowledgeFile(_input?: unknown): Promise<never> {
  throw new KnowledgeApiError('knowledge_service_unavailable');
}
async function retryKnowledgeFile(_input?: unknown): Promise<never> {
  throw new KnowledgeApiError('knowledge_service_unavailable');
}

function SectionTip({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return;
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, [open]);

  return (
    <span
      ref={ref}
      className={styles.tipAnchor}
      onKeyDown={(e) => { if (e.key === 'Escape') setOpen(false); }}
    >
      <button
        type="button"
        className={styles.tipIcon}
        onClick={() => setOpen((v) => !v)}
        aria-label="Info"
      >
        ?
      </button>
      {open && (
        <span className={styles.tipPopover} role="tooltip">
          {text}
        </span>
      )}
    </span>
  );
}

const COLOR_PRESETS = [
  '#8B5CF6', '#3B82F6', '#10B981', '#F59E0B',
  '#EF4444', '#EC4899', '#06B6D4', '#84CC16',
];

const ACCEPTED_REFERENCE_FILE_TYPES = 'text/*,application/json,application/xml,application/pdf,.docx,.xlsx,.pptx';
const ACCEPTED_KNOWLEDGE_FILE_TYPES = '.txt,.md,.json,.csv,.html,.xml,.yaml,.yml,.css,.js,.ts,.jsx,.tsx,.py,.java,.kt,.swift,.go,.sql,.pdf,.docx,.pptx,.xlsx';

type KnowledgeSourceCacheEntry = {
  rawFile: File;
  prepared?: Awaited<ReturnType<typeof prepareKnowledgeUpload>>;
};

function deriveKnowledgeFileStatus(
  file: SkillKnowledgeBaseFile,
  knowledgeEligible: boolean,
): SkillKnowledgeBaseFile['status'] {
  if (file.status === 'ready' && !knowledgeEligible) {
    return 'disabled';
  }
  return file.status;
}

function resolveKnowledgeErrorCode(error: unknown, fallback: SkillKnowledgeErrorCode): SkillKnowledgeErrorCode {
  if (error instanceof KnowledgeApiError && error.code) {
    return error.code as SkillKnowledgeErrorCode;
  }
  if (error instanceof Error && error.message) {
    return error.message as SkillKnowledgeErrorCode;
  }
  return fallback;
}

function buildKnowledgeProviderCapabilityKey(
  provider:
    | {
      id?: string;
      apiKey?: string;
      baseURLText?: string | null;
      models?: Array<{ id: string }>;
      apiKeyPreview?: string;
    }
    | undefined,
): string {
  if (!provider) {
    return 'no-openai-provider';
  }
  return [
    provider.id ?? '',
    provider.apiKey ?? '',
    provider.baseURLText ?? '',
    ...(provider.models ?? []).map((model) => model.id),
  ].join('|');
}

function hasProviderKey(provider: { apiKey?: string; apiKeyPreview?: string } | undefined): boolean {
  if (!provider) return false;
  return Boolean(provider.apiKey?.trim() || provider.apiKeyPreview?.trim());
}

function applyKnowledgeFileTerminalStatus(
  knowledgeBase: SkillKnowledgeBase | null,
  fileId: string,
  status: 'ready' | 'failed',
): SkillKnowledgeBase | null {
  if (!knowledgeBase) {
    return knowledgeBase;
  }
  const nextUpdatedAt = new Date().toISOString();
  return {
    ...knowledgeBase,
    updatedAt: nextUpdatedAt,
    files: knowledgeBase.files.map((file) => {
      if (file.id !== fileId) {
        return file;
      }
      return {
        ...file,
        status,
        errorCode: status === 'failed' ? 'knowledge_index_failed' : undefined,
        updatedAt: nextUpdatedAt,
      };
    }),
  };
}

async function extractPDFText(file: File): Promise<string> {
  const { getDocument, GlobalWorkerOptions } = await import('pdfjs-dist');
  GlobalWorkerOptions.workerSrc = new URL(
    'pdfjs-dist/build/pdf.worker.min.mjs',
    import.meta.url,
  ).toString();

  const buffer = await file.arrayBuffer();
  const pdf = await getDocument({ data: buffer }).promise;
  const pages: string[] = [];
  for (let i = 1; i <= pdf.numPages; i++) {
    const page = await pdf.getPage(i);
    const textContent = await page.getTextContent();
    const pageText = textContent.items
      .map((item) => ('str' in item ? item.str : ''))
      .join('');
    if (pageText) pages.push(pageText);
  }
  return pages.join('\n');
}

export function SkillEditPage() {
  const t = useTranslations('skills');
  const router = useRouter();
  const searchParams = useSearchParams();
  const editId = searchParams.get('id');

  const [name, setName] = useState('');
  const [icon, setIcon] = useState('🤖');
  const [color, setColor] = useState('#8B5CF6');
  const [description, setDescription] = useState('');
  const [systemPrompt, setSystemPrompt] = useState('');
  const [knowledgeFiles, setKnowledgeFiles] = useState<SkillKnowledgeFile[]>([]);
  const [knowledgeBase, setKnowledgeBase] = useState<SkillKnowledgeBase | null>(null);
  const [knowledgeRuntime, setKnowledgeRuntime] = useState<Awaited<ReturnType<typeof fetchKnowledgeRuntimeConfig>> | null>(null);
  const [knowledgeEligibility, setKnowledgeEligibility] = useState<Awaited<ReturnType<typeof checkKnowledgeEligibility>> | null>(null);
  const [useMemory, setUseMemory] = useState(true);
  const [saving, setSaving] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [knowledgePendingId, setKnowledgePendingId] = useState<string | 'new' | null>(null);
  const [knowledgeProviderCapabilityKey, setKnowledgeProviderCapabilityKey] = useState('no-openai-provider');
  const [knowledgeRefreshTick, setKnowledgeRefreshTick] = useState(0);
  const [knowledgeCtaDismissedKey, setKnowledgeCtaDismissedKey] = useState<string | null>(null);
  const [providerKeySummary, setProviderKeySummary] = useState({
    hasOpenAIKey: false,
    hasOpenRouterKey: false,
    openAIProviderId: null as string | null,
  });

  const referenceFileInputRef = useRef<HTMLInputElement>(null);
  const knowledgeFileInputRef = useRef<HTMLInputElement>(null);
  const knowledgePickerTargetIdRef = useRef<string | null>(null);
  const knowledgeSourceCacheRef = useRef<Record<string, KnowledgeSourceCacheEntry>>({});
  const originalKnowledgeBaseRef = useRef<SkillKnowledgeBase | null>(null);
  const indexingPollAbortRef = useRef<AbortController | null>(null);
  const knowledgeCtaKeyRef = useRef<string | null>(null);
  const getOpenAIProvider = useCallback(() => {
    const providers = getVanillaStore().getState().providers ?? [];
    return providers.find((provider) => provider.kind === 'openAI' && provider.apiKey.trim());
  }, []);

  useEffect(() => {
    const syncCapabilityKey = () => {
      const providers = getVanillaStore().getState().providers ?? [];
      const openAIProvider = providers.find((provider) => provider.kind === 'openAI' && provider.apiKey.trim());
      const nextKey = buildKnowledgeProviderCapabilityKey(openAIProvider);
      const nextSummary = {
        hasOpenAIKey: providers.some((provider) => provider.kind === 'openAI' && hasProviderKey(provider)),
        hasOpenRouterKey: providers.some((provider) => provider.kind === 'openRouter' && hasProviderKey(provider)),
        openAIProviderId: providers.find((provider) => provider.kind === 'openAI' && hasProviderKey(provider))?.id
          ?? providers.find((provider) => provider.kind === 'openAI')?.id
          ?? null,
      };
      setKnowledgeProviderCapabilityKey((currentKey) => (currentKey === nextKey ? currentKey : nextKey));
      setProviderKeySummary((currentSummary) => (
        currentSummary.hasOpenAIKey === nextSummary.hasOpenAIKey
        && currentSummary.hasOpenRouterKey === nextSummary.hasOpenRouterKey
        && currentSummary.openAIProviderId === nextSummary.openAIProviderId
          ? currentSummary
          : nextSummary
      ));
    };
    syncCapabilityKey();
    const unsubscribe = getVanillaStore().subscribe(syncCapabilityKey);
    return () => unsubscribe();
  }, [getOpenAIProvider]);

  useEffect(() => {
    if (!editId) {
      originalKnowledgeBaseRef.current = null;
      knowledgeSourceCacheRef.current = {};
      return;
    }

    const applySkill = (skill: Skill) => {
      setName(skill.name);
      setIcon(skill.icon);
      setColor(skill.color);
      setDescription(skill.description);
      setSystemPrompt(skill.systemPrompt);
      setKnowledgeFiles(skill.knowledgeFiles ?? []);
      setKnowledgeBase(skill.knowledgeBase ?? null);
      originalKnowledgeBaseRef.current = skill.knowledgeBase ?? null;
      setUseMemory(skill.useMemory);
      setDirty(false);
      knowledgeSourceCacheRef.current = {};
    };

    // Try loading immediately; subscribe and wait when the store has not finished hydrating.
    const skill = getSkillById(getVanillaStore(), editId);
    if (skill) {
      applySkill(skill);
      return;
    }

    const unsubscribe = getVanillaStore().subscribe(() => {
      const s = getSkillById(getVanillaStore(), editId);
      if (s) {
        applySkill(s);
        unsubscribe();
      }
    });
    return () => unsubscribe();
  }, [editId]);

  useEffect(() => {
    let cancelled = false;

    async function loadKnowledgeRuntime() {
      try {
        const runtime = await fetchKnowledgeRuntimeConfig();
        if (cancelled) return;
        setKnowledgeRuntime(runtime);
      } catch {
        if (!cancelled) {
          setKnowledgeRuntime(null);
          setKnowledgeEligibility({ eligible: false, errorCode: 'knowledge_service_unavailable' });
        }
      }
    }

    void loadKnowledgeRuntime();

    return () => {
      cancelled = true;
    };
  }, [knowledgeRefreshTick]);

  useEffect(() => {
    if (!knowledgeRuntime) {
      return;
    }

    const runtime = knowledgeRuntime;
    let cancelled = false;

    async function refreshKnowledgeEligibility() {
      try {
        const openAIProvider = getOpenAIProvider();
        const eligibility = await checkKnowledgeEligibility({
          apiKey: openAIProvider?.apiKey,
          baseURL: openAIProvider?.baseURLText,
          retrievalModel: runtime.retrievalModel,
          enabledModels: openAIProvider?.models?.map((model) => model.id) ?? [],
        });
        if (!cancelled) {
          setKnowledgeEligibility(eligibility);
        }
      } catch {
        if (!cancelled) {
          setKnowledgeEligibility({ eligible: false, errorCode: 'knowledge_service_unavailable' });
        }
      }
    }

    void refreshKnowledgeEligibility();

    return () => {
      cancelled = true;
    };
  }, [getOpenAIProvider, knowledgeProviderCapabilityKey, knowledgeRuntime, knowledgeRefreshTick]);

  useEffect(() => {
    const openAIProvider = getOpenAIProvider();
    const indexingFile = knowledgeBase?.files.find((file) => file.status === 'indexing' && file.openAIFileId);
    if (!knowledgeBase || !indexingFile?.openAIFileId || !openAIProvider) {
      indexingPollAbortRef.current?.abort();
      indexingPollAbortRef.current = null;
      return;
    }
    const openAIFileId = indexingFile.openAIFileId;

    indexingPollAbortRef.current?.abort();
    const abort = new AbortController();
    indexingPollAbortRef.current = abort;

    void (async () => {
      const maxAttempts = 30;
      for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 3000));
        if (abort.signal.aborted) {
          return;
        }

        const result = await checkKnowledgeFileStatus({
          apiKey: openAIProvider.apiKey,
          baseURL: openAIProvider.baseURLText,
          vectorStoreId: knowledgeBase.vectorStoreId,
          openAIFileId,
        });
        if (abort.signal.aborted) {
          return;
        }
        if (!result) {
          continue;
        }

        if (result.status === 'ready' || result.status === 'failed') {
          const terminalStatus = result.status === 'ready' ? 'ready' : 'failed';
          setKnowledgeBase((currentKnowledgeBase) => applyKnowledgeFileTerminalStatus(
            currentKnowledgeBase,
            indexingFile.id,
            terminalStatus,
          ));
          return;
        }
      }

      if (!abort.signal.aborted) {
        setKnowledgeBase((currentKnowledgeBase) => applyKnowledgeFileTerminalStatus(
          currentKnowledgeBase,
          indexingFile.id,
          'failed',
        ));
      }
    })().catch(() => {});

    return () => {
      abort.abort();
    };
  }, [getOpenAIProvider, knowledgeBase, knowledgeProviderCapabilityKey]);

  const markDirty = useCallback(() => setDirty(true), []);

  const showKnowledgeToast = useCallback((errorCode: SkillKnowledgeErrorCode | string) => {
    showToast(t(errorCode));
  }, [t]);

  const currentOriginalOpenAIFileIds = useCallback(() => new Set(
    (originalKnowledgeBaseRef.current?.files ?? [])
      .map((file) => file.openAIFileId?.trim())
      .filter((value): value is string => Boolean(value)),
  ), []);

  const cleanupDraftKnowledgeResources = useCallback(async () => {
    const plan = buildDraftKnowledgeCleanupPlan({
      originalKnowledgeBase: originalKnowledgeBaseRef.current,
      currentKnowledgeBase: knowledgeBase,
    });
    if (!plan) {
      return true;
    }

    const openAIProvider = getOpenAIProvider();
    if (!openAIProvider) {
      showKnowledgeToast('openai_not_configured');
      return false;
    }

    try {
      await cleanupDraftKnowledge({
        apiKey: openAIProvider.apiKey,
        baseURL: openAIProvider.baseURLText,
        vectorStoreId: plan.vectorStoreId,
        openAIFileIds: plan.openAIFileIds,
        deleteVectorStore: plan.deleteVectorStore,
      });
      return true;
    } catch (error) {
      showKnowledgeToast(resolveKnowledgeErrorCode(error, 'knowledge_cleanup_failed'));
      return false;
    }
  }, [getOpenAIProvider, knowledgeBase, showKnowledgeToast]);

  const openInNewTab = useCallback((href: string) => {
    if (typeof window === 'undefined') return;
    window.open(href, '_blank', 'noopener,noreferrer');
  }, []);

  const handleKnowledgeEligibilityRetry = useCallback(() => {
    setKnowledgeRefreshTick((value) => value + 1);
  }, []);

  const dismissKnowledgeCta = useCallback((key: string) => {
    setKnowledgeCtaDismissedKey(key);
  }, []);

  const handleSave = useCallback(async () => {
    if (!name.trim() || !systemPrompt.trim()) return;
    const store = getVanillaStore();
    setSaving(true);
    const openAIProvider = getOpenAIProvider();
    const needsRemoteCleanup = editId
      ? requiresRemoteKnowledgeCleanup({
        originalKnowledgeBase: originalKnowledgeBaseRef.current,
        currentKnowledgeBase: knowledgeBase,
      })
      : false;
    if (needsRemoteCleanup && !openAIProvider) {
      showKnowledgeToast('openai_not_configured');
      setSaving(false);
      return;
    }
    const body = {
      name: name.trim(),
      icon,
      color,
      description: description.trim(),
      systemPrompt: systemPrompt.trim(),
      modelCapabilityHint: 'any',
      starterMessages: [],
      knowledgeFiles,
      knowledgeBase,
      useMemory,
      ...(needsRemoteCleanup && openAIProvider ? {
        knowledgeCleanup: {
          apiKey: openAIProvider.apiKey,
          baseURL: openAIProvider.baseURLText,
        },
      } : {}),
    };
    try {
      if (editId) {
        await updateSkillOp(store, editId, body);
      } else {
        await createSkillOp(store, body);
      }
      router.push('/skills');
    } catch (error) {
      showToast(error instanceof Error ? error.message : String(error));
      setSaving(false);
    }
  }, [name, icon, color, description, systemPrompt, knowledgeFiles, knowledgeBase, useMemory, editId, router, getOpenAIProvider, showKnowledgeToast]);

  const handleBack = useCallback(async () => {
    if (dirty) {
      if (!confirm(t('discardChangesMessage'))) return;
      if (!(await cleanupDraftKnowledgeResources())) return;
    }
    router.push('/skills');
  }, [cleanupDraftKnowledgeResources, dirty, t, router]);

  const handleReferenceFileUpload = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    e.target.value = '';

    try {
      const sizeError = validateReferenceFileSize(file.size);
      if (sizeError) {
        showKnowledgeToast(sizeError);
        return;
      }

      const isPDF = file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf');
      const isOffice = /\.(docx|xlsx|pptx)$/i.test(file.name);
      const content = isPDF ? await extractPDFText(file)
                    : isOffice ? await parseOfficeFile(file)
                    : await file.text();

      if (!content.trim()) {
        showToast(t('fileReadError'));
        return;
      }

      const newFile = buildReferenceKnowledgeFile({
        id: crypto.randomUUID(),
        name: file.name,
        mimeType: file.type || (isPDF ? 'application/pdf' : 'text/plain'),
        sourceType: isPDF ? 'pdf_text' : 'text',
        content,
      });
      setKnowledgeFiles((prev) => [...prev, newFile]);
      markDirty();
    } catch {
      showToast(t('fileReadError'));
    }
  }, [markDirty, showKnowledgeToast, t]);

  const removeKnowledgeFile = useCallback((id: string) => {
    setKnowledgeFiles((prev) => prev.filter((f) => f.id !== id));
    markDirty();
  }, [markDirty]);

  const beginKnowledgePick = useCallback((targetFileId: string | null = null) => {
    knowledgePickerTargetIdRef.current = targetFileId;
    knowledgeFileInputRef.current?.click();
  }, []);

  const applyKnowledgeUploadFailure = useCallback((params: {
    fileId: string;
    displayName: string;
    displayMimeType: string;
    displaySizeBytes: number;
    ingestionMode: SkillKnowledgeBaseFile['ingestionMode'];
    extractedFrom?: SkillKnowledgeBaseFile['extractedFrom'];
    openAIFileId?: string;
    errorCode: SkillKnowledgeErrorCode;
    createdAt?: string;
  }) => {
    if (!knowledgeRuntime) return;
    setKnowledgeBase((prev) => upsertLocalKnowledgeBase({
      knowledgeBase: prev,
      provider: knowledgeRuntime.provider,
      retrievalModel: knowledgeRuntime.retrievalModel,
      expiresAfterDays: knowledgeRuntime.expiresAfterDays,
      vectorStoreId: prev?.vectorStoreId,
      file: buildLocalKnowledgeBaseFile({
        id: params.fileId,
        name: params.displayName,
        mimeType: params.displayMimeType,
        sizeBytes: params.displaySizeBytes,
        ingestionMode: params.ingestionMode,
        extractedFrom: params.extractedFrom,
        openAIFileId: params.openAIFileId,
        status: 'failed',
        errorCode: params.errorCode,
        createdAt: params.createdAt,
      }),
    }));
  }, [knowledgeRuntime]);

  const handleKnowledgeFileUpload = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const sourceFile = e.target.files?.[0];
    if (!sourceFile) return;
    e.target.value = '';
    if (!knowledgeRuntime) {
      showKnowledgeToast('knowledge_service_unavailable');
      return;
    }

    const targetFileId = knowledgePickerTargetIdRef.current;
    knowledgePickerTargetIdRef.current = null;
    const targetFile = targetFileId
      ? knowledgeBase?.files.find((file) => file.id === targetFileId)
      : undefined;

    const openAIProvider = getOpenAIProvider();
    if (!openAIProvider) {
      showKnowledgeToast('openai_not_configured');
      return;
    }

    if (!isKnowledgeFileTypeSupported(sourceFile, knowledgeRuntime.supportedFileTypes)) {
      showKnowledgeToast('unsupported_file_type');
      return;
    }

    let prepared: Awaited<ReturnType<typeof prepareKnowledgeUpload>>;
    try {
      prepared = await prepareKnowledgeUpload(sourceFile);
    } catch (error) {
      const errorCode = resolveKnowledgeErrorCode(error, 'knowledge_extract_failed');
      const failedId = targetFile?.id ?? crypto.randomUUID();
      knowledgeSourceCacheRef.current[failedId] = { rawFile: sourceFile };
      applyKnowledgeUploadFailure({
        fileId: failedId,
        displayName: sourceFile.name,
        displayMimeType: sourceFile.type || 'application/octet-stream',
        displaySizeBytes: sourceFile.size,
        ingestionMode: 'extracted_text',
        extractedFrom: 'xlsx',
        errorCode,
        createdAt: targetFile?.createdAt,
      });
      setKnowledgePendingId(null);
      markDirty();
      showKnowledgeToast(errorCode);
      return;
    }

    const existingBytes = Math.max(0, sumKnowledgeBaseBytes(knowledgeBase) - (targetFile?.sizeBytes ?? 0));
    const existingCount = Math.max(0, (knowledgeBase?.files.length ?? 0) - (targetFile ? 1 : 0));
    const quotaError = validateKnowledgeBaseQuota({
      existingCount,
      existingBytes,
      nextFileBytes: prepared.displaySizeBytes,
    });
    if (quotaError) {
      showKnowledgeToast(quotaError);
      return;
    }

    const localFileId = targetFile?.id ?? crypto.randomUUID();
    const previousKnowledgeBase = knowledgeBase;
    const originalOpenAIFileIds = currentOriginalOpenAIFileIds();
    const targetIsPersistedRemoteFile = Boolean(
      targetFile?.openAIFileId && originalOpenAIFileIds.has(targetFile.openAIFileId),
    );
    knowledgeSourceCacheRef.current[localFileId] = {
      rawFile: sourceFile,
      prepared,
    };
    setKnowledgePendingId(localFileId);
    if (knowledgeRuntime) {
      setKnowledgeBase((prev) => upsertLocalKnowledgeBase({
        knowledgeBase: prev,
        provider: knowledgeRuntime.provider,
        retrievalModel: knowledgeRuntime.retrievalModel,
        expiresAfterDays: knowledgeRuntime.expiresAfterDays,
        vectorStoreId: prev?.vectorStoreId,
        file: buildLocalKnowledgeBaseFile({
          id: localFileId,
          name: prepared.displayName,
          mimeType: prepared.displayMimeType,
          sizeBytes: prepared.displaySizeBytes,
          ingestionMode: prepared.ingestionMode,
          extractedFrom: prepared.extractedFrom,
          status: targetFile ? 'replacing' : 'uploading',
          createdAt: targetFile?.createdAt,
        }),
      }));
    }

    try {
      const nextKnowledgeBase = targetFile
        ? targetIsPersistedRemoteFile
          ? await uploadKnowledgeFile({
            apiKey: openAIProvider.apiKey,
            baseURL: openAIProvider.baseURLText,
            provider: knowledgeRuntime.provider,
            retrievalModel: knowledgeRuntime.retrievalModel,
            expiresAfterDays: knowledgeRuntime.expiresAfterDays,
            knowledgeBase: knowledgeBase ?? {
              provider: knowledgeRuntime.provider,
              retrievalModel: knowledgeRuntime.retrievalModel,
              vectorStoreId: '',
              expiresAfterDays: knowledgeRuntime.expiresAfterDays,
              files: [],
              updatedAt: new Date().toISOString(),
            },
            targetFileId: targetFile.id,
            file: prepared.uploadFile,
            displayName: prepared.displayName,
            displayMimeType: prepared.displayMimeType,
            displaySizeBytes: prepared.displaySizeBytes,
            ingestionMode: prepared.ingestionMode,
            extractedFrom: prepared.extractedFrom,
          })
          : await replaceKnowledgeFile({
            apiKey: openAIProvider.apiKey,
            baseURL: openAIProvider.baseURLText,
            provider: knowledgeRuntime.provider,
            retrievalModel: knowledgeRuntime.retrievalModel,
            expiresAfterDays: knowledgeRuntime.expiresAfterDays,
            knowledgeBase: knowledgeBase ?? {
              provider: knowledgeRuntime.provider,
              retrievalModel: knowledgeRuntime.retrievalModel,
              vectorStoreId: '',
              expiresAfterDays: knowledgeRuntime.expiresAfterDays,
              files: [],
              updatedAt: new Date().toISOString(),
            },
            targetFileId: targetFile.id,
            targetOpenAIFileId: targetFile.openAIFileId,
            file: prepared.uploadFile,
            displayName: prepared.displayName,
            displayMimeType: prepared.displayMimeType,
            displaySizeBytes: prepared.displaySizeBytes,
            ingestionMode: prepared.ingestionMode,
            extractedFrom: prepared.extractedFrom,
          })
        : await uploadKnowledgeFile({
          apiKey: openAIProvider.apiKey,
          baseURL: openAIProvider.baseURLText,
          provider: knowledgeRuntime.provider,
          retrievalModel: knowledgeRuntime.retrievalModel,
          expiresAfterDays: knowledgeRuntime.expiresAfterDays,
          knowledgeBase,
          targetFileId: localFileId,
          file: prepared.uploadFile,
          displayName: prepared.displayName,
          displayMimeType: prepared.displayMimeType,
          displaySizeBytes: prepared.displaySizeBytes,
          ingestionMode: prepared.ingestionMode,
          extractedFrom: prepared.extractedFrom,
        });

      setKnowledgeBase(nextKnowledgeBase);
      markDirty();
    } catch (error) {
      const errorCode = resolveKnowledgeErrorCode(error, 'knowledge_upload_failed');
      if (targetFile && targetIsPersistedRemoteFile) {
        setKnowledgeBase(previousKnowledgeBase);
      } else if (targetFile) {
        applyKnowledgeUploadFailure({
          fileId: targetFile.id,
          displayName: prepared.displayName,
          displayMimeType: prepared.displayMimeType,
          displaySizeBytes: prepared.displaySizeBytes,
          ingestionMode: prepared.ingestionMode,
          extractedFrom: prepared.extractedFrom,
          openAIFileId: targetFile.openAIFileId,
          errorCode,
          createdAt: targetFile.createdAt,
        });
      } else {
        applyKnowledgeUploadFailure({
          fileId: localFileId,
          displayName: prepared.displayName,
          displayMimeType: prepared.displayMimeType,
          displaySizeBytes: prepared.displaySizeBytes,
          ingestionMode: prepared.ingestionMode,
          extractedFrom: prepared.extractedFrom,
          errorCode,
        });
      }
      markDirty();
      showKnowledgeToast(errorCode);
    } finally {
      setKnowledgePendingId(null);
    }
  }, [applyKnowledgeUploadFailure, currentOriginalOpenAIFileIds, getOpenAIProvider, knowledgeBase, knowledgeRuntime, markDirty, showKnowledgeToast]);

  const handleRetryKnowledgeFile = useCallback(async (file: SkillKnowledgeBaseFile) => {
    if (!knowledgeRuntime) return;

    const cacheEntry = knowledgeSourceCacheRef.current[file.id];
    if (!cacheEntry) {
      showToast(t('knowledgeRetryUnavailable'));
      return;
    }

    const openAIProvider = getOpenAIProvider();
    if (!openAIProvider) {
      showKnowledgeToast('openai_not_configured');
      return;
    }

    setKnowledgePendingId(file.id);

    let prepared = cacheEntry.prepared;
    try {
      if (!prepared) {
        prepared = await prepareKnowledgeUpload(cacheEntry.rawFile);
        knowledgeSourceCacheRef.current[file.id] = { ...cacheEntry, prepared };
      }
    } catch (error) {
      const errorCode = resolveKnowledgeErrorCode(error, 'knowledge_extract_failed');
      applyKnowledgeUploadFailure({
        fileId: file.id,
        displayName: file.name,
        displayMimeType: file.mimeType,
        displaySizeBytes: file.sizeBytes,
        ingestionMode: file.ingestionMode,
        extractedFrom: file.extractedFrom,
        errorCode,
        createdAt: file.createdAt,
      });
      setKnowledgePendingId(null);
      showKnowledgeToast(errorCode);
      return;
    }

    setKnowledgeBase((prev) => upsertLocalKnowledgeBase({
      knowledgeBase: prev,
      provider: knowledgeRuntime.provider,
      retrievalModel: knowledgeRuntime.retrievalModel,
      expiresAfterDays: knowledgeRuntime.expiresAfterDays,
      vectorStoreId: prev?.vectorStoreId,
      file: buildLocalKnowledgeBaseFile({
        id: file.id,
        name: prepared.displayName,
        mimeType: prepared.displayMimeType,
        sizeBytes: prepared.displaySizeBytes,
        ingestionMode: prepared.ingestionMode,
        extractedFrom: prepared.extractedFrom,
        status: 'uploading',
        createdAt: file.createdAt,
      }),
    }));

    try {
      const nextKnowledgeBase = await retryKnowledgeFile({
        apiKey: openAIProvider.apiKey,
        baseURL: openAIProvider.baseURLText,
        provider: knowledgeRuntime.provider,
        retrievalModel: knowledgeRuntime.retrievalModel,
        expiresAfterDays: knowledgeRuntime.expiresAfterDays,
        knowledgeBase,
        targetFileId: file.id,
        file: prepared.uploadFile,
        displayName: prepared.displayName,
        displayMimeType: prepared.displayMimeType,
        displaySizeBytes: prepared.displaySizeBytes,
        ingestionMode: prepared.ingestionMode,
        extractedFrom: prepared.extractedFrom,
      });

      setKnowledgeBase(nextKnowledgeBase);
      markDirty();
    } catch (error) {
      const errorCode = resolveKnowledgeErrorCode(error, 'knowledge_upload_failed');
      applyKnowledgeUploadFailure({
        fileId: file.id,
        displayName: prepared.displayName,
        displayMimeType: prepared.displayMimeType,
        displaySizeBytes: prepared.displaySizeBytes,
        ingestionMode: prepared.ingestionMode,
        extractedFrom: prepared.extractedFrom,
        errorCode,
        createdAt: file.createdAt,
      });
      markDirty();
      showKnowledgeToast(errorCode);
    } finally {
      setKnowledgePendingId(null);
    }
  }, [applyKnowledgeUploadFailure, getOpenAIProvider, knowledgeBase, knowledgeRuntime, markDirty, showKnowledgeToast, t]);

  const handleDeleteKnowledgeFile = useCallback(async (file: SkillKnowledgeBaseFile) => {
    const openAIProvider = getOpenAIProvider();
    const previousKnowledgeBase = knowledgeBase;
    const originalOpenAIFileIds = currentOriginalOpenAIFileIds();
    const isPersistedRemoteFile = Boolean(
      file.openAIFileId && originalOpenAIFileIds.has(file.openAIFileId),
    );
    const hasRemoteDraftResource = Boolean(file.openAIFileId && !isPersistedRemoteFile);

    setKnowledgePendingId(file.id);
    if (hasRemoteDraftResource) {
      setKnowledgeBase((prev) => prev ? upsertLocalKnowledgeBase({
        knowledgeBase: prev,
        provider: prev.provider,
        retrievalModel: prev.retrievalModel,
        expiresAfterDays: prev.expiresAfterDays,
        vectorStoreId: prev.vectorStoreId,
        file: {
          ...file,
          status: 'deleting',
          updatedAt: new Date().toISOString(),
        },
      }) : prev);
    }

    try {
      if (!knowledgeBase) {
        setKnowledgeBase((prev) => removeLocalKnowledgeBaseFile(prev, file.id));
      } else if (hasRemoteDraftResource) {
        if (!openAIProvider) {
          throw new KnowledgeApiError('openai_not_configured');
        }
        await cleanupDraftKnowledge({
          apiKey: openAIProvider.apiKey,
          baseURL: openAIProvider.baseURLText,
          vectorStoreId: knowledgeBase.vectorStoreId,
          openAIFileIds: file.openAIFileId ? [file.openAIFileId] : [],
          deleteVectorStore: !originalKnowledgeBaseRef.current
            && knowledgeBase.files.length === 1
            && knowledgeBase.vectorStoreId.trim().length > 0,
        });
        setKnowledgeBase((prev) => removeLocalKnowledgeBaseFile(prev, file.id));
      } else {
        setKnowledgeBase((prev) => removeLocalKnowledgeBaseFile(prev, file.id));
      }
      delete knowledgeSourceCacheRef.current[file.id];
      markDirty();
    } catch (error) {
      setKnowledgeBase(previousKnowledgeBase);
      showKnowledgeToast(resolveKnowledgeErrorCode(error, 'knowledge_cleanup_failed'));
    } finally {
      setKnowledgePendingId(null);
    }
  }, [currentOriginalOpenAIFileIds, getOpenAIProvider, knowledgeBase, markDirty, showKnowledgeToast]);

  const knowledgeUsedBytes = sumKnowledgeBaseBytes(knowledgeBase);
  const maxKnowledgeFiles = MAX_KNOWLEDGE_FILES;
  const knowledgeMutating = knowledgePendingId !== null;
  const knowledgeEligible = knowledgeEligibility?.eligible ?? false;
  const canSave = name.trim().length > 0 && systemPrompt.trim().length > 0 && !knowledgeMutating;
  const knowledgeEligibilityError = knowledgeEligibility?.eligible === false
    ? (knowledgeEligibility.errorCode ?? 'knowledge_service_unavailable')
    : null;
  const requiredModelLabel = knowledgeEligibility?.requiredModel ?? knowledgeRuntime?.retrievalModel ?? '';
  const knowledgeEligibilityHint = knowledgeEligibility === null
    ? t('knowledgeReadyHint')
    : knowledgeEligible
      ? t('knowledgeReadyHint')
      : knowledgeEligibility.errorCode
        ? t(knowledgeEligibility.errorCode, {
          model: knowledgeEligibility.requiredModel ?? knowledgeRuntime?.retrievalModel ?? '',
        })
        : t('knowledge_service_unavailable');
  const isOpenRouterOnly = knowledgeEligibilityError === 'openai_not_configured'
    && !providerKeySummary.hasOpenAIKey
    && providerKeySummary.hasOpenRouterKey;
  const openAISetupHref = '/providers/new?kind=openAI&entry_point=skill_edit';
  const openAIManageHref = providerKeySummary.openAIProviderId
    ? `/providers/${providerKeySummary.openAIProviderId}`
    : openAISetupHref;
  const knowledgeCta = useMemo(() => {
    if (!knowledgeEligibilityError) return null;

    if (isOpenRouterOnly) {
      const key = 'openrouter_only';
      return {
        key,
        message: t('knowledgeCtaOpenRouterOnly'),
        primaryLabel: t('knowledgeCtaPrimaryAddOpenAIKey'),
        secondaryLabel: t('knowledgeCtaSecondaryLater'),
        onPrimary: () => openInNewTab(openAISetupHref),
        onSecondary: () => dismissKnowledgeCta(key),
      };
    }

    if (knowledgeEligibilityError === 'openai_not_configured') {
      const key = 'openai_not_configured';
      return {
        key,
        message: t('knowledgeCtaOpenAIRequired'),
        primaryLabel: t('knowledgeCtaPrimaryConfigureOpenAI'),
        secondaryLabel: t('knowledgeCtaSecondaryLater'),
        onPrimary: () => openInNewTab(openAISetupHref),
        onSecondary: () => dismissKnowledgeCta(key),
      };
    }

    if (knowledgeEligibilityError === 'openai_endpoint_not_official') {
      const key = 'openai_endpoint_not_official';
      return {
        key,
        message: t('knowledgeCtaEndpointNotOfficial'),
        primaryLabel: t('knowledgeCtaPrimaryCheckOpenAIConfig'),
        secondaryLabel: t('knowledgeCtaSecondaryLater'),
        onPrimary: () => openInNewTab(openAIManageHref),
        onSecondary: () => dismissKnowledgeCta(key),
      };
    }

    if (knowledgeEligibilityError === 'retrieval_model_not_enabled') {
      const key = 'retrieval_model_not_enabled';
      return {
        key,
        message: t('knowledgeCtaRetrievalModel', { model: requiredModelLabel }),
        primaryLabel: t('knowledgeCtaPrimaryAddModel'),
        secondaryLabel: t('knowledgeCtaSecondaryLater'),
        onPrimary: () => openInNewTab(openAIManageHref),
        onSecondary: () => dismissKnowledgeCta(key),
      };
    }

    if (knowledgeEligibilityError === 'knowledge_service_unavailable') {
      const key = 'knowledge_service_unavailable';
      return {
        key,
        message: t('knowledgeCtaServiceUnavailable'),
        primaryLabel: t('knowledgeCtaPrimaryRetryLater'),
        secondaryLabel: t('knowledgeCtaSecondaryContinue'),
        onPrimary: handleKnowledgeEligibilityRetry,
        onSecondary: () => dismissKnowledgeCta(key),
      };
    }

    return null;
  }, [
    knowledgeEligibilityError,
    isOpenRouterOnly,
    t,
    requiredModelLabel,
    openInNewTab,
    openAISetupHref,
    openAIManageHref,
    dismissKnowledgeCta,
    handleKnowledgeEligibilityRetry,
  ]);
  const knowledgeCtaKey = knowledgeCta?.key ?? null;
  const shouldShowKnowledgeCta = Boolean(knowledgeCta) && knowledgeCtaDismissedKey !== knowledgeCtaKey;

  useEffect(() => {
    if (knowledgeCtaKeyRef.current !== knowledgeCtaKey) {
      knowledgeCtaKeyRef.current = knowledgeCtaKey;
      setKnowledgeCtaDismissedKey(null);
    }
  }, [knowledgeCtaKey]);

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <button type="button" className={styles.backBtn} onClick={handleBack}>
          ← {t('title')}
        </button>
        <h1 className={styles.title}>
          {editId ? t('editSkill') : t('newSkill')}
        </h1>
        <button
          type="button"
          className={styles.saveBtn}
          onClick={handleSave}
          disabled={!canSave || saving}
        >
          {saving ? t('saving') : t('save')}
        </button>
      </div>

      <div className={styles.form}>
        {/* ── Hero: Icon + Color + Name + Description ── */}
        <section className={styles.section}>
          <div className={styles.heroRow}>
            <div className={styles.heroPreview} style={{ background: color }}>
              <span className={styles.heroEmoji}>{icon || '🤖'}</span>
            </div>
            <div className={styles.heroFields}>
              <input
                className={styles.input}
                value={name}
                onChange={(e) => { setName(e.target.value); markDirty(); }}
                placeholder={t('namePlaceholder')}
                maxLength={50}
              />
              <input
                className={styles.input}
                value={description}
                onChange={(e) => { setDescription(e.target.value); markDirty(); }}
                placeholder={t('descriptionPlaceholder')}
                maxLength={100}
              />
            </div>
          </div>

          <div className={styles.heroMeta}>
            <div className={styles.field}>
              <label className={styles.label}>{t('icon')}</label>
              <input
                className={styles.iconInput}
                value={icon}
                maxLength={4}
                onChange={(e) => { setIcon(e.target.value); markDirty(); }}
                placeholder="🤖"
              />
            </div>
            <div className={styles.field}>
              <label className={styles.label}>{t('color')}</label>
              <div className={styles.colorRow}>
                {COLOR_PRESETS.map((preset) => (
                  <button
                    key={preset}
                    type="button"
                    className={`${styles.colorDot} ${color === preset ? styles.colorDotActive : ''}`}
                    style={{ background: preset }}
                    onClick={() => { setColor(preset); markDirty(); }}
                    aria-label={preset}
                  />
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* ── Prompt ── */}
        <section className={styles.section}>
          <div className={styles.field}>
            <label className={styles.label}>
              {t('instructions')}
              <SectionTip text={t('tipInstructions')} />
            </label>
            <textarea
              className={styles.textarea}
              value={systemPrompt}
              onChange={(e) => { setSystemPrompt(e.target.value); markDirty(); }}
              placeholder={t('instructionsPlaceholder')}
              rows={8}
              maxLength={4000}
            />
            <div className={styles.charCount}>{systemPrompt.length}/4000</div>
          </div>
        </section>

        {/* ── Knowledge ── */}
        <section className={styles.section}>
          <h3 className={styles.sectionTitle}>{t('knowledgeSectionTitle')}</h3>

          <div className={styles.field}>
            <label className={styles.label}>
              {t('referenceFiles')}
              <SectionTip text={t('tipReferenceFiles')} />
              <span className={styles.quota}>
                {t('filesQuota', { count: knowledgeFiles.length, max: maxKnowledgeFiles })}
              </span>
            </label>
            {knowledgeFiles.length === 0 && (
              <div className={styles.emptyHint}>{t('noReferenceFiles')}</div>
            )}
            {knowledgeFiles.map((file) => (
              <div key={file.id} className={styles.fileItem}>
                <div className={styles.fileInfo}>
                  <span className={styles.fileName}>{file.name}</span>
                  <span className={styles.fileSize}>
                    {t('referenceFileChars', { count: file.charCount })}
                  </span>
                </div>
                <button
                  type="button"
                  className={styles.removeBtn}
                  onClick={() => removeKnowledgeFile(file.id)}
                  aria-label="Remove"
                >
                  ×
                </button>
              </div>
            ))}
            {knowledgeFiles.length < maxKnowledgeFiles && (
              <>
                <input
                  ref={referenceFileInputRef}
                  type="file"
                  accept={ACCEPTED_REFERENCE_FILE_TYPES}
                  onChange={handleReferenceFileUpload}
                  className={styles.hiddenInput}
                  tabIndex={-1}
                />
                <button
                  type="button"
                  className={styles.addFileBtn}
                  onClick={() => referenceFileInputRef.current?.click()}
                >
                  + {t('addFile')}
                </button>
              </>
            )}
          </div>

          <div className={styles.divider} />

          <div className={styles.field}>
            <label className={styles.label}>
              {t('knowledgeBaseFiles')}
              <SectionTip text={t('tipKnowledgeBaseFiles')} />
              <span className={styles.quota}>
                {t('filesQuota', { count: knowledgeBase?.files.length ?? 0, max: maxKnowledgeFiles })}
              </span>
            </label>
            <div className={styles.knowledgeMeta}>
              {knowledgeRuntime ? (
                <>
                  <span>{knowledgeRuntime.provider} - {knowledgeRuntime.retrievalModel}</span>
                  <span>{formatBytes(knowledgeUsedBytes)} / {formatBytes(100 * 1024 * 1024)}</span>
                </>
              ) : (
                <span>{t('knowledge_service_unavailable')}</span>
              )}
            </div>
            <div className={styles.emptyHint}>{knowledgeEligibilityHint}</div>
            {shouldShowKnowledgeCta && knowledgeCta && (
              <div className={styles.knowledgeCta}>
                <div className={styles.knowledgeCtaText}>{knowledgeCta.message}</div>
                <div className={styles.knowledgeCtaActions}>
                  <button
                    type="button"
                    className={styles.knowledgeCtaPrimary}
                    onClick={knowledgeCta.onPrimary}
                  >
                    {knowledgeCta.primaryLabel}
                  </button>
                  <button
                    type="button"
                    className={styles.knowledgeCtaSecondary}
                    onClick={knowledgeCta.onSecondary}
                  >
                    {knowledgeCta.secondaryLabel}
                  </button>
                </div>
              </div>
            )}
            {(knowledgeBase?.files.length ?? 0) === 0 && (
              <div className={styles.emptyHint}>{t('knowledgeEmptyHint')}</div>
            )}
            {knowledgeBase?.files.map((file) => (
              (() => {
                const displayStatus = deriveKnowledgeFileStatus(file, knowledgeEligible);
                return (
                  <div key={file.id} className={styles.fileItem}>
                    <div className={styles.fileInfo}>
                      <span className={styles.fileName}>{file.name}</span>
                      <span className={styles.fileSize}>
                        {formatBytes(file.sizeBytes)} - {t(`knowledgeStatus${displayStatus[0].toUpperCase()}${displayStatus.slice(1)}`)}
                        {file.errorCode ? ` - ${t(file.errorCode)}` : ''}
                      </span>
                    </div>
                    <div className={styles.fileActions}>
                      {displayStatus === 'ready' && (
                        <button
                          type="button"
                          className={styles.inlineActionBtn}
                          onClick={() => beginKnowledgePick(file.id)}
                          aria-label={t('replaceKnowledgeFile')}
                          disabled={knowledgeMutating}
                        >
                          {t('replaceKnowledgeFile')}
                        </button>
                      )}
                      {file.status === 'failed' && knowledgeEligible && (
                        <button
                          type="button"
                          className={styles.inlineActionBtn}
                          onClick={() => void handleRetryKnowledgeFile(file)}
                          aria-label={t('retryKnowledgeFile')}
                          disabled={knowledgeMutating}
                        >
                          {t('retryKnowledgeFile')}
                        </button>
                      )}
                      <button
                        type="button"
                        className={styles.inlineActionBtn}
                        onClick={() => void handleDeleteKnowledgeFile(file)}
                        aria-label={t('deleteKnowledgeFile')}
                        disabled={knowledgeMutating}
                      >
                        {t('deleteKnowledgeFile')}
                      </button>
                    </div>
                  </div>
                );
              })()
            ))}
            {(knowledgeBase?.files.length ?? 0) < maxKnowledgeFiles && (
              <>
                <input
                  ref={knowledgeFileInputRef}
                  type="file"
                  accept={ACCEPTED_KNOWLEDGE_FILE_TYPES}
                  onChange={handleKnowledgeFileUpload}
                  className={styles.hiddenInput}
                  tabIndex={-1}
                  data-knowledge-input="true"
                />
                <button
                  type="button"
                  className={styles.addFileBtn}
                  onClick={() => beginKnowledgePick()}
                  disabled={!knowledgeEligible || knowledgeMutating}
                  aria-label={t('addKnowledgeFile')}
                >
                  + {t('addKnowledgeFile')}
                </button>
              </>
            )}
          </div>
        </section>

        {/* ── Advanced ── */}
        <section className={styles.section}>
          <div className={styles.toggleRow}>
            <div>
              <div className={styles.toggleLabel}>{t('useMemory')}</div>
              <div className={styles.toggleHint}>{t('useMemoryHint')}</div>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={useMemory}
              className={`${styles.toggle} ${useMemory ? styles.toggleOn : ''}`}
              onClick={() => { setUseMemory((v) => !v); markDirty(); }}
            />
          </div>
        </section>
      </div>
    </div>
  );
}
