"use client";

import { useId, useState } from "react";
import { useTranslations } from "next-intl";
import { ChevronRight, Wrench } from "lucide-react";
import type { ChatMessage } from "@oriveo/shared";
import styles from "./UnhandledToolCallCard.module.css";

const MAX_ARGUMENT_BYTES = 2_048;

interface Props {
  calls?: NonNullable<ChatMessage["unhandledToolCalls"]>;
  notice?: ChatMessage["toolFallbackNotice"];
}

export function UnhandledToolCallCard({ calls = [], notice }: Props) {
  const [expanded, setExpanded] = useState(false);
  const detailsId = useId();
  const t = useTranslations("pages.chat");
  if (calls.length === 0) {
    if (notice !== "library_not_searched") return null;
    return (
      <section className={styles.card} data-testid="tool-fallback-notice">
        <div className={`${styles.header} ${styles.staticHeader}`}>
          <Wrench className={styles.icon} aria-hidden="true" />
          <span className={styles.summary}>{t("toolFallbackLibraryNotSearched")}</span>
        </div>
      </section>
    );
  }
  const displayNames = calls.map((call) => call.name || "?");
  const names = displayNames.join(", ");
  const summary = calls.length === 1
    ? t("toolCallUnhandledSingle", { name: names })
    : t("toolCallUnhandledMultiple", { names });

  return (
    <section className={styles.card} data-testid="unhandled-tool-call-card">
      <button
        type="button"
        className={styles.header}
        aria-expanded={expanded}
        aria-controls={detailsId}
        onClick={() => setExpanded((value) => !value)}
      >
        <Wrench className={styles.icon} aria-hidden="true" />
        <span className={styles.summary}>{summary}</span>
        <ChevronRight
          className={`${styles.chevron} ${expanded ? styles.expanded : ""}`}
          aria-hidden="true"
        />
      </button>
      {expanded ? (
        <div className={styles.details} id={detailsId}>
          <div className={styles.title}>{t("toolCallRequestTitle")}</div>
          {calls.map((call, index) => {
            const formatted = formatToolCallArguments(call.arguments);
            return (
              <div className={styles.call} key={call.id}>
                <code className={styles.name}>{displayNames[index]}</code>
                <pre className={styles.arguments}>{formatted.text}</pre>
                {formatted.truncated ? (
                  <span className={styles.truncated}>{t("toolCallArgumentsTruncated")}</span>
                ) : null}
              </div>
            );
          })}
        </div>
      ) : null}
    </section>
  );
}

export function formatToolCallArguments(raw: string): { text: string; truncated: boolean } {
  let source = raw;
  try {
    source = JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    // Preserve malformed provider output verbatim; this view never executes it.
  }
  const bytes = new TextEncoder().encode(source);
  if (bytes.length <= MAX_ARGUMENT_BYTES) return { text: source, truncated: false };
  return {
    text: decodeCompleteUtf8Prefix(bytes, MAX_ARGUMENT_BYTES),
    truncated: true,
  };
}

function decodeCompleteUtf8Prefix(bytes: Uint8Array, maxBytes: number): string {
  for (let end = Math.min(bytes.length, maxBytes); end >= 0; end -= 1) {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, end));
    } catch {
      // UTF-8 code points use at most four bytes, so this backs up only across
      // the split scalar at the boundary and never inserts U+FFFD.
    }
  }
  return "";
}
