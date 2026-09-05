"use client";

import { useState, useMemo } from "react";
import { useTranslations } from "next-intl";
import type { ProviderErrorSource } from "@oriveo/shared";
import { isRateLimitError } from "../../lib/utils/error-classify";
import { resolveErrorCopyKey } from "../../lib/utils/chat-stream-utils";
import styles from "./MessageRecoveryCard.module.css";

interface MessageRecoveryCardProps {
  state: "failed" | "interrupted";
  /** Title localized when the message was stored; a fallback for old data without errorKind. New data is always translated at render time. */
  errorTitle?: string;
  errorDetail?: string;
  /** Semantic identifier of the failure. Recovery actions are decided from this alone, never from the already-localized errorTitle text. */
  errorKind?: string;
  /** For a provider response, only the stored redacted original is shown; rewriting the copy by kind is not allowed. */
  errorSource?: ProviderErrorSource;
  /**
   * Whether the stored errorDetail is itself a localization template. Other failures store the raw
   * backend or SDK error in errorDetail and it must be shown verbatim, not run through a template.
   */
  errorDetailIsLocalized?: boolean;
  /**
   * The stored errorDetail is **raw technical text from the transport layer**, not something meant
   * for a user: an offline device produces `Failed to fetch`, for example. It is replaced by a
   * localized sentence chosen by kind, with the original demoted into the technical details
   * section. Warning: text returned by a provider or relay does **not** take this path - that is
   * the single source of truth for the user-facing body (see the errorSource rule).
   */
  detailIsInternalTechnicalText?: boolean;
  /** Raw, unlocalized backend error text, shown only in the technical details section; falls back to errorDetail when absent. */
  technicalDetail?: string;
  disabled?: boolean;
  onRetry?: () => void;
  onEdit?: () => void;
  onContinue?: () => void;
  onSwitchModel?: () => void;
  primaryActionLabel?: string;
  onPrimaryAction?: () => void;
}

// Classification goes through lib/utils/error-classify; a local copy of the keywords would drift from it.

export function MessageRecoveryCard({
  state,
  errorTitle,
  errorDetail,
  errorKind,
  errorSource,
  errorDetailIsLocalized = false,
  detailIsInternalTechnicalText = false,
  technicalDetail,
  disabled = false,
  onRetry,
  onEdit,
  onContinue,
  onSwitchModel,
  primaryActionLabel,
  onPrimaryAction,
}: MessageRecoveryCardProps) {
  const t = useTranslations("pages.chat.recovery");
  const tErrors = useTranslations("errors");
  const [detailOpen, setDetailOpen] = useState(false);

  const showSwitchModel = useMemo(
    () =>
      state === "failed" &&
      onSwitchModel &&
      isRateLimitError(errorKind, errorTitle, errorDetail),
    [state, onSwitchModel, errorKind, errorTitle, errorDetail],
  );
  const isFailed = state === "failed";

  // -- Order in which failure copy is decided: only the semantic identifier is persisted and
  // localization happens at render time, matching the iOS and Android clients.
  // 1. errorKind resolves to an errors.* copy key -> translated on the spot, following the current
  //    UI language
  // 2. It does not resolve (old data without errorKind, or non-ProviderError semantics such as
  //    Library) -> fall back to the errorTitle / errorDetail strings stored at failure time (their
  //    language is frozen at that moment, but there is at least some copy)
  const copyKey = isFailed && errorSource !== "provider"
    ? resolveErrorCopyKey(errorKind)
    : null;
  const resolvedTitle = copyKey ? tErrors(`${copyKey}.title`) : errorTitle;
  // The body is replaced with render-time copy in two cases: the stored errorDetail is itself a
  // localization template, or it is raw technical text from our own transport layer (`Failed to
  // fetch` and the like) that tells the user nothing. Everything else - provider and relay
  // originals - is kept verbatim.
  const localizeDetail = Boolean(copyKey) && (errorDetailIsLocalized || detailIsInternalTechnicalText);
  const resolvedDetail = copyKey && localizeDetail ? tErrors(`${copyKey}.message`) : errorDetail;

  const cardClassName = `${styles.card} ${isFailed ? styles.cardFailed : styles.cardInterrupted}`;

  return (
    <div className={cardClassName}>
      {/* Header */}
      <div className={styles.header}>
        {isFailed ? (
          /* Warning triangle icon */
          <svg
            className={styles.icon}
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" />
            <line x1="12" y1="9" x2="12" y2="13" />
            <line x1="12" y1="17" x2="12.01" y2="17" />
          </svg>
        ) : (
          /* Pause circle icon */
          <svg
            className={styles.icon}
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <circle cx="12" cy="12" r="10" />
            <line x1="10" y1="15" x2="10" y2="9" />
            <line x1="14" y1="15" x2="14" y2="9" />
          </svg>
        )}
        <h3 className={styles.title}>
          {isFailed ? resolvedTitle : t("interruptedTitle")}
        </h3>
      </div>

      {/* Description */}
      {isFailed && resolvedDetail && !detailOpen && (
        <p className={styles.description}>{resolvedDetail}</p>
      )}
      {!isFailed && (
        <p className={styles.description}>{t("interruptedDesc")}</p>
      )}

      {/* Actions */}
      <div className={styles.actions}>
        {isFailed ? (
          <>
            {onPrimaryAction && primaryActionLabel ? (
              <button
                type="button"
                className={styles.primaryBtn}
                onClick={onPrimaryAction}
                disabled={disabled}
              >
                {primaryActionLabel}
              </button>
            ) : (
              !onPrimaryAction &&
              onRetry && (
                <button
                  type="button"
                  className={styles.primaryBtn}
                  onClick={onRetry}
                  disabled={disabled}
                >
                  {t("retryBtn")}
                </button>
              )
            )}
            {onEdit && !onPrimaryAction && (
              <button
                type="button"
                className={styles.secondaryBtn}
                onClick={onEdit}
                disabled={disabled}
              >
                {t("editBtn")}
              </button>
            )}
            {showSwitchModel && !onPrimaryAction && (
              <button
                type="button"
                className={styles.secondaryBtn}
                onClick={onSwitchModel}
                disabled={disabled}
              >
                {t("switchModelBtn")}
              </button>
            )}
          </>
        ) : (
          <>
            {/* Interrupted state: continue generating (primary, keeps the partial) plus regenerate (secondary, answers the whole turn again), matching the iOS and Android retry experience */}
            {onContinue && (
              <button
                type="button"
                className={styles.primaryBtn}
                onClick={onContinue}
                disabled={disabled}
              >
                {t("continueBtn")}
              </button>
            )}
            {onRetry && (
              <button
                type="button"
                className={onContinue ? styles.secondaryBtn : styles.primaryBtn}
                onClick={onRetry}
                disabled={disabled}
              >
                {t("regenerateBtn")}
              </button>
            )}
          </>
        )}
      </div>

      {/* Technical details (failed only): the raw unlocalized text first, falling back to errorDetail */}
      {isFailed && (technicalDetail || errorDetail) && (
        <>
          <button
            type="button"
            className={styles.detailToggle}
            onClick={() => setDetailOpen((v) => !v)}
            disabled={disabled}
          >
            {t("technicalDetails")}
          </button>
          <div className={styles.detailContentWrap} data-open={detailOpen}>
            <div className={styles.detailContentInner}>
              <pre className={styles.detailContent}>
                {technicalDetail || errorDetail}
              </pre>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
