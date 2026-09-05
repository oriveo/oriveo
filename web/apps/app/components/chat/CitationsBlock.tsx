"use client";

/**
 * Citation block for web search results.
 *
 * Behaviour:
 *   - collapsed to the first 3 entries by default, with a "show all N" toggle
 *   - each entry shows favicon, title and domain, and opens in a new tab
 *   - streaming updates render without flicker: the list keys on normalizeUrl to keep the order
 *     stable
 *   - light and dark styling switches on the `[data-theme='dark']` selector, following the manual
 *     theme from useTheme
 */

import { memo, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import type { Citation } from "@oriveo/shared";
import { FileText } from "lucide-react";
import { normalizeUrl } from "../../lib/core/providers/transport/citation-utils";
import styles from "./CitationsBlock.module.css";

interface CitationsBlockProps {
  citations: Citation[];
  /** True while streaming; the expand button is hidden then, to avoid layout jitter. */
  isStreaming?: boolean;
}

const DEFAULT_PREVIEW_COUNT = 3;
const GOOGLE_FAVICON = "https://www.google.com/s2/favicons";

function getDomain(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

function safeCitationURL(raw: string): string | null {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function isLibraryContextReference(citation: Citation): boolean {
  if (
    (citation.source !== "notion" && citation.source !== "google") ||
    !citation.docId
  ) {
    return false;
  }
  try {
    const url = new URL(citation.url);
    return (
      url.protocol === "library-context:" &&
      url.hostname === citation.source
    );
  } catch {
    return false;
  }
}

function getFaviconURL(c: Citation): string | null {
  const domain = getDomain(c.url);
  if (!domain) return null;
  return `${GOOGLE_FAVICON}?domain=${encodeURIComponent(domain)}&sz=32`;
}

function GlobeIcon() {
  return (
    <svg
      className={styles.faviconFallback}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
    </svg>
  );
}

function FaviconImg({ citation }: { citation: Citation }) {
  const src = getFaviconURL(citation);
  const [failed, setFailed] = useState(false);
  if (!src || failed) {
    return (
      <span className={styles.favicon} aria-hidden="true">
        <GlobeIcon />
      </span>
    );
  }
  return (
    <span className={styles.favicon} aria-hidden="true">
      <img
        className={styles.faviconImg}
        src={src}
        alt=""
        loading="lazy"
        decoding="async"
        referrerPolicy="no-referrer"
        onError={() => setFailed(true)}
      />
    </span>
  );
}

function LibrarySourceMark({ citation }: { citation: Citation }) {
  if (citation.source !== "notion" && citation.source !== "google") {
    return <FaviconImg citation={citation} />;
  }
  return (
    <span
      className={styles.favicon}
      data-library-source={citation.source}
      aria-hidden="true"
    >
      {citation.source === "notion" ? "N" : <FileText size={12} />}
    </span>
  );
}

function CitationRow({
  citation,
  positionIndex,
}: {
  citation: Citation;
  positionIndex: number;
}) {
  const url = safeCitationURL(citation.url || "");
  const isLocalReference = isLibraryContextReference(citation);
  if (!url && !isLocalReference) return null;
  const domain = url ? getDomain(url) : "";
  const displayIndex =
    typeof citation.index === "number" ? citation.index : positionIndex;
  const sourceLabel =
    citation.source === "notion"
      ? "Notion"
      : citation.source === "google"
        ? "Google Drive"
        : domain;
  const editedDate =
    citation.lastEdited && !Number.isNaN(Date.parse(citation.lastEdited))
      ? new Date(citation.lastEdited).toLocaleDateString()
      : null;
  const content = (
    <>
      <span className={styles.indexBadge} aria-hidden="true">
        {displayIndex}
      </span>
      <LibrarySourceMark citation={citation} />
      <span className={styles.itemTextWrap}>
        <span className={styles.title}>{citation.title || domain || url}</span>
        {sourceLabel || editedDate ? (
          <span className={styles.domain}>
            {sourceLabel || ""}
            {sourceLabel && editedDate ? " - " : ""}
            {editedDate ? (
              <time dateTime={citation.lastEdited}>{editedDate}</time>
            ) : null}
          </span>
        ) : null}
        {citation.snippet ? (
          <span className={styles.snippet}>{citation.snippet}</span>
        ) : null}
      </span>
    </>
  );
  if (!url) {
    return (
      <div
        className={`${styles.item} ${styles.itemStatic}`}
        data-library-context-ref="true"
        title={citation.title || citation.docId}
      >
        {content}
      </div>
    );
  }
  return (
    <a
      className={styles.item}
      href={url}
      target="_blank"
      rel="noopener noreferrer nofollow"
      title={citation.title || url}
    >
      {content}
    </a>
  );
}

export const CitationsBlock = memo(function CitationsBlock({
  citations,
  isStreaming = false,
}: CitationsBlockProps) {
  const t = useTranslations("pages.chat");
  const [expanded, setExpanded] = useState(false);

  // HTTPS citations are links. Request-only Library context keeps a local
  // identity reference when the source did not provide a trusted URL.
  const valid = useMemo(
    () =>
      citations.filter(
        (c) =>
          typeof c.url === "string" &&
          (safeCitationURL(c.url) !== null || isLibraryContextReference(c)),
      ),
    [citations],
  );

  if (valid.length === 0) return null;

  const previewCount = DEFAULT_PREVIEW_COUNT;
  const overflowCount = Math.max(0, valid.length - previewCount);
  const visible = expanded ? valid : valid.slice(0, previewCount);

  return (
    <section className={styles.container} aria-label={t("citationsLabel")}>
      <header className={styles.header}>
        <span>{t("citationsLabel")}</span>
        <span aria-hidden="true">-</span>
        <span>{valid.length}</span>
      </header>
      <div className={styles.list}>
        {visible.map((c, idx) => (
          <CitationRow
            // normalizeUrl gives a stable key, so reordering after streaming dedupe does not unmount and remount rows
            key={
              c.docId && (c.source === "notion" || c.source === "google")
                ? `library:${c.source}:${c.docId}`
                : normalizeUrl(c.url) || `idx:${idx}`
            }
            citation={c}
            positionIndex={idx + 1}
          />
        ))}
      </div>
      {!isStreaming && overflowCount > 0 && (
        <button
          type="button"
          className={styles.toggleButton}
          onClick={() => setExpanded((prev) => !prev)}
        >
          {/* Collapsed state shows "show all N sources", where N is the total rather than the remainder */}
          {expanded
            ? t("citationsCollapse")
            : t("citationsExpand", { count: valid.length })}
        </button>
      )}
    </section>
  );
});
