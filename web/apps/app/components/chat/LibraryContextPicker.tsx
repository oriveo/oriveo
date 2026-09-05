"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { Button, Dialog } from "@oriveo/ui";
import { Check, FileText, Library, LoaderCircle, ScanSearch, Search } from "lucide-react";
import { executeLibraryTool } from "../../lib/core/library/api";
import type {
  LibraryDocumentRef,
  LibraryListResult,
  LibraryProvider,
  LibraryQuota,
  LibrarySearchResult,
} from "../../lib/core/library/types";
import { dedupeLibraryDocumentRefs } from "../../lib/core/chat/library-direct-context";
import styles from "./LibraryContextPicker.module.css";

/**
 * Unified Library entry panel.
 *
 * One panel covers both "Research Library" and "Add context": they serve the same user intent and
 * differ only in who picks the documents. The two
 * options inside the panel are orthogonal and mutually exclusive: scope (search my library, where
 * the agent retrieves over several steps on its own) and naming (pick documents, whose full text
 * goes straight into the context).
 */
interface LibraryContextPickerProps {
  open: boolean;
  sources: LibraryProvider[];
  selected: LibraryDocumentRef[];
  /** Whether research mode is available (backend libraryAgentic and the server retrieval switch, plus provider gating). When it is not, the scope option is greyed out with an explanation. */
  researchAvailable: boolean;
  /**
   * Available, but running through server-side retrieval because the model does not support agentic
   * retrieval.
   *
   * Greying this case out along with the rest would tell the user "the current model does not
   * support automatic retrieval" while retrieval is in fact still possible, just on the server. The
   * hint has to say where the search happens rather than reuse the agent wording.
   */
  researchServerSide?: boolean;
  /**
   * The metadata snapshot has not arrived, so which path applies cannot be decided yet. Saying
   * "not supported" would report a cold-start window as a missing model capability, and the user's
   * existing switch value must not be cleared over it either.
   */
  researchPending?: boolean;
  /**
   * Why it is definitely unavailable, when the state is not pending: the backend switch is off, the
   * provider is on the retrieval denylist, or the model itself does not support it. Unavailable
   * without a reason (older call sites, cases not broken down yet) falls back to the general "model
   * not supported" copy rather than adding a branch.
   */
  researchUnavailableReason?: "serverDisabled" | "providerDenied" | "modelUnsupported";
  researchEnabled: boolean;
  onResearchEnabledChange: (enabled: boolean) => void;
  /** Researches left this month; null means unlimited or unknown and is not displayed. */
  remainingResearches: number | null;
  /**
   * Maximum documents selectable at once (backend libraryRuntimeConfig.directMaxDocuments).
   * Selected documents are spliced into the context in full, so without a cap the user would only
   * hit a provider 400 at send time. Reporting it at selection time is what tells them they picked
   * too many.
   */
  maxDocuments: number;
  onChange: (documents: LibraryDocumentRef[]) => void;
  onClose: () => void;
  onQuota?: (quota: LibraryQuota) => void;
}

type CursorMap = Partial<Record<LibraryProvider, string>>;

export function LibraryContextPicker({
  open,
  sources,
  selected,
  researchAvailable,
  researchServerSide = false,
  researchPending = false,
  researchUnavailableReason,
  researchEnabled,
  onResearchEnabledChange,
  remainingResearches,
  maxDocuments,
  onChange,
  onClose,
  onQuota,
}: LibraryContextPickerProps) {
  const t = useTranslations("library");
  const [query, setQuery] = useState("");
  const [documents, setDocuments] = useState<LibraryDocumentRef[]>([]);
  const [cursors, setCursors] = useState<CursorMap>({});
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState<LibraryProvider | null>(null);
  const [error, setError] = useState(false);
  const requestRef = useRef<AbortController | null>(null);
  const initialSelectionRef = useRef<LibraryDocumentRef[]>([]);

  const activeSources = useMemo(
    () => [...new Set(sources)].filter((source): source is LibraryProvider =>
      source === "notion" || source === "google"),
    [sources],
  );

  const loadRoot = useCallback(async () => {
    requestRef.current?.abort();
    const controller = new AbortController();
    requestRef.current = controller;
    setLoading(true);
    setLoadingMore(null);
    setError(false);
    try {
      const responses = await Promise.all(
        activeSources.map(async (source) => {
          const response = await executeLibraryTool(
            "library_list",
            { source },
            controller.signal,
          );
          return {
            source,
            result: response.result as LibraryListResult,
            quota: response.quota,
          };
        }),
      );
      if (controller.signal.aborted) return;
      responses.forEach(({ quota }) => {
        if (quota) onQuota?.(quota);
      });
      setDocuments(dedupeLibraryDocumentRefs(responses.flatMap(({ source, result }) =>
        result.items.map((item) => ({
          docId: item.id,
          source,
          title: item.title,
          ...(item.url ? { url: item.url } : {}),
        })),
      )));
      setCursors(Object.fromEntries(
        responses.flatMap(({ source, result }) =>
          result.nextCursor ? [[source, result.nextCursor]] : []),
      ));
    } catch (requestError) {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [activeSources, onQuota]);

  useEffect(() => {
    if (!open) {
      requestRef.current?.abort();
      setLoading(false);
      setLoadingMore(null);
      return;
    }
    initialSelectionRef.current = selected;
    setQuery("");
    setLoadingMore(null);
    void loadRoot();
    return () => requestRef.current?.abort();
  }, [loadRoot, open]);

  const handleCancel = useCallback(() => {
    onChange(initialSelectionRef.current);
    onClose();
  }, [onChange, onClose]);

  const handleSearch = useCallback(async () => {
    const normalizedQuery = query.trim();
    if (!normalizedQuery) {
      await loadRoot();
      return;
    }
    requestRef.current?.abort();
    const controller = new AbortController();
    requestRef.current = controller;
    setLoading(true);
    setLoadingMore(null);
    setError(false);
    try {
      const response = await executeLibraryTool(
        "library_search",
        { query: normalizedQuery, sources: activeSources, limit: 30 },
        controller.signal,
      );
      if (controller.signal.aborted) return;
      if (response.quota) onQuota?.(response.quota);
      const result = response.result as LibrarySearchResult;
      setDocuments(dedupeLibraryDocumentRefs(result.hits.map((hit) => ({
        docId: hit.docId,
        source: hit.source,
        title: hit.title,
        url: hit.url,
        lastEdited: hit.lastEdited,
      }))));
      setCursors({});
    } catch (requestError) {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [activeSources, loadRoot, onQuota, query]);

  const handleLoadMore = useCallback(async (source: LibraryProvider) => {
    const cursor = cursors[source];
    if (!cursor || loadingMore) return;
    setLoadingMore(source);
    setError(false);
    const controller = new AbortController();
    requestRef.current = controller;
    try {
      const response = await executeLibraryTool(
        "library_list",
        { source, cursor },
        controller.signal,
      );
      if (controller.signal.aborted) return;
      if (response.quota) onQuota?.(response.quota);
      const result = response.result as LibraryListResult;
      setDocuments((current) => dedupeLibraryDocumentRefs([
        ...current,
        ...result.items.map((item) => ({
          docId: item.id,
          source,
          title: item.title,
          ...(item.url ? { url: item.url } : {}),
        })),
      ]));
      setCursors((current) => ({
        ...current,
        [source]: result.nextCursor || undefined,
      }));
    } catch (requestError) {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setLoadingMore(null);
    }
  }, [cursors, loadingMore, onQuota]);

  const selectedKeys = useMemo(
    () => new Set(selected.map((document) => documentKey(document))),
    [selected],
  );

  const atLimit = selected.length >= maxDocuments;

  const toggleDocument = (document: LibraryDocumentRef) => {
    const key = documentKey(document);
    if (selectedKeys.has(key)) {
      onChange(selected.filter((candidate) => documentKey(candidate) !== key));
      return;
    }
    if (atLimit) return;
    // Mutually exclusive: naming specific documents turns off the agent's own retrieval.
    onResearchEnabledChange(false);
    onChange(dedupeLibraryDocumentRefs([...selected, document]));
  };

  return (
    <Dialog
      open={open}
      onClose={handleCancel}
      size="lg"
      padded={false}
      ariaLabelledBy="library-context-picker-title"
      lockBodyScroll
    >
      <div className={styles.header}>
        <span className={styles.headerIcon} aria-hidden="true"><Library size={18} /></span>
        <div>
          <h2 id="library-context-picker-title">{t("title")}</h2>
          {/*
            Library quota is surfaced here because the panel header is the only place that comes
            before the action that spends it; anywhere else the user has to dig into settings or
            wait for the error card once it runs out.
          */}
          <p>
            {remainingResearches != null
              ? t("leftThisMonth", { count: remainingResearches })
              : t("contextPickerSelected", { count: selected.length })}
          </p>
        </div>
      </div>

      {/* Scope option: it answers where to look, not whether to look, so it is deliberately not a peer of the document picker below */}
      <button
        type="button"
        className={styles.scopeCard}
        data-selected={researchEnabled || undefined}
        data-disabled={!researchAvailable || undefined}
        aria-pressed={researchEnabled}
        disabled={!researchAvailable}
        onClick={() => {
          const next = !researchEnabled;
          onResearchEnabledChange(next);
          // Mutually exclusive: either a scoped search or named documents, never both.
          if (next) onChange([]);
        }}
      >
        <span className={styles.scopeIcon} aria-hidden="true"><ScanSearch size={16} /></span>
        <span className={styles.scopeCopy}>
          <span className={styles.scopeTitle}>{t("searchMyLibrary")}</span>
          <span className={styles.scopeHint}>
            {!researchAvailable
              ? researchUnavailableReason === "serverDisabled"
                ? t("researchDisabledHint")
                : researchUnavailableReason === "providerDenied"
                  ? t("researchProviderDeniedHint")
                  : t("researchUnavailableHint")
              : researchPending
                // The evidence has not arrived yet: saying "not supported" would be wrong, since it
                // is most likely available a second later. But "loading" alone is not enough either
                // - an offline cold start may never resolve, so an alternative path is offered too.
                ? t("researchPendingHint")
                : researchServerSide
                  ? t("searchMyLibraryServerHint")
                  : t("searchMyLibraryHint")}
          </span>
        </span>
        {/*
          When unavailable the placeholder box stays and is only greyed out rather than removed:
          removing it leaves the scope row one column short of the document rows below, the
          checkboxes stop lining up and the layout looks broken. Keeping the entry plus the
          scopeHint explains why, and the actionable alternative is the document picker below.
        */}
        <span
          className={styles.selection}
          data-disabled={!researchAvailable || undefined}
          aria-hidden="true"
        >
          {researchAvailable && researchEnabled ? <Check size={15} strokeWidth={2.5} /> : null}
        </span>
      </button>

      <p className={styles.sectionLabel} data-at-limit={atLimit || undefined}>
        <span>{t("pickSpecificDocuments")}</span>
        <span className={styles.selectionCount}>
          {t("contextPickerSelectionCount", {
            selected: selected.length,
            max: maxDocuments,
          })}
        </span>
      </p>
      {atLimit ? (
        <p className={styles.limitHint} role="status">
          {t("contextPickerLimitReached", { max: maxDocuments })}
        </p>
      ) : null}

      <form
        className={styles.search}
        onSubmit={(event) => {
          event.preventDefault();
          void handleSearch();
        }}
      >
        <Search size={16} aria-hidden="true" />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("contextPickerSearchPlaceholder")}
          aria-label={t("contextPickerSearchPlaceholder")}
        />
        <button type="submit" disabled={loading}>{t("contextPickerSearch")}</button>
      </form>

      <div className={styles.results} aria-live="polite">
        {loading ? (
          <div className={styles.status}><LoaderCircle className={styles.spinner} size={18} />{t("contextPickerLoading")}</div>
        ) : error ? (
          <div className={styles.status} data-tone="error">
            <span>{t("contextPickerError")}</span>
            <button type="button" onClick={() => void (query.trim() ? handleSearch() : loadRoot())}>{t("retry")}</button>
          </div>
        ) : documents.length === 0 ? (
          <div className={styles.status}>{t("contextPickerEmpty")}</div>
        ) : (
          <>
            <div className={styles.documentList}>
              {documents.map((document) => {
                const selectedDocument = selectedKeys.has(documentKey(document));
                return (
                  <button
                    key={documentKey(document)}
                    type="button"
                    className={styles.documentRow}
                    data-selected={selectedDocument || undefined}
                    aria-pressed={selectedDocument}
                    // Once at the limit, unselected rows stop responding: one has to be removed before another can be added.
                    disabled={atLimit && !selectedDocument}
                    onClick={() => toggleDocument(document)}
                  >
                    <span className={styles.sourceIcon} data-source={document.source} aria-hidden="true">
                      {document.source === "notion" ? "N" : <FileText size={15} />}
                    </span>
                    <span className={styles.documentCopy}>
                      <span className={styles.documentTitle}>{document.title}</span>
                      <span className={styles.documentSource}>{document.source === "notion" ? "Notion" : "Google Drive"}</span>
                    </span>
                    <span className={styles.selection} aria-hidden="true">
                      {selectedDocument ? <Check size={15} strokeWidth={2.5} /> : null}
                    </span>
                  </button>
                );
              })}
            </div>
            {Object.entries(cursors).map(([source, cursor]) => cursor ? (
              <button
                key={source}
                type="button"
                className={styles.loadMore}
                onClick={() => void handleLoadMore(source as LibraryProvider)}
                disabled={loadingMore != null}
              >
                {loadingMore === source ? t("contextPickerLoading") : t("contextPickerLoadMore", {
                  source: source === "notion" ? "Notion" : "Google Drive",
                })}
              </button>
            ) : null)}
          </>
        )}
      </div>

      <div className={styles.actions}>
        <Button tone="secondary" onClick={handleCancel}>{t("cancel")}</Button>
        <Button onClick={onClose}>{t("contextPickerDone")}</Button>
      </div>
    </Dialog>
  );
}

function documentKey(document: LibraryDocumentRef): string {
  return `${document.source}:${document.docId}`;
}
