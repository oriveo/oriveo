"use client";

import { useTranslations } from "next-intl";
import { Cloud, Files, Gauge, HelpCircle, ShieldAlert } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { Button, Dialog } from "@oriveo/ui";
import { useAppStore } from "../../providers/StoreProvider";
import { resolveLibraryConfirmation } from "../../lib/core/library/confirmation";
import styles from "./LibraryConfirmationDialog.module.css";

type Reason =
  | "sensitive"
  | "high_cost"
  | "broad_read"
  | "unknown_relay"
  | "hosted_provider";

/**
 * One icon and hue per reason. A single orange ShieldAlert for every case makes "large document"
 * and "unknown relay" look exactly like "sensitive content", so the icon carries no information.
 */
const REASON_VISUALS: Record<Reason, { icon: LucideIcon; tone: string }> = {
  sensitive: { icon: ShieldAlert, tone: "warning" },
  high_cost: { icon: Gauge, tone: "info" },
  broad_read: { icon: Files, tone: "info" },
  unknown_relay: { icon: HelpCircle, tone: "warning" },
  hosted_provider: { icon: Cloud, tone: "primary" },
};

/** Server kind enum mapped to plain wording. Unknown values pass through unchanged, so a new backend type does not blank out the whole row. */
const KIND_KEYS: Record<string, string> = {
  secret: "confirm.kind.secret",
  cred: "confirm.kind.cred",
  pii: "confirm.kind.pii",
};

export function LibraryConfirmationDialog() {
  const t = useTranslations("library");
  const confirmation = useAppStore((state) => state.libraryConfirmation);

  const reason = (confirmation?.reason ?? "sensitive") as Reason;
  const visual = REASON_VISUALS[reason] ?? REASON_VISUALS.sensitive;
  const Icon = visual.icon;

  // Two columns, label and value, instead of a row of bare chips.
  // Multiple values are separated by a middle dot: a separator with a language attribute would
  // have to be maintained across all 16 locales.
  const rows: { key: string; label?: string; value: string }[] = [];
  if (confirmation?.detail.docTitles?.length) {
    rows.push({
      key: "documents",
      label: t("confirm.document"),
      value: confirmation.detail.docTitles.join(" - "),
    });
  }
  if (confirmation?.detail.kinds?.length) {
    rows.push({
      key: "kinds",
      label: t("confirm.mayContain"),
      value: confirmation.detail.kinds
        .map((kind) => (KIND_KEYS[kind] ? t(KIND_KEYS[kind]) : kind))
        .join(" - "),
    });
  }
  if (confirmation?.detail.estTokens) {
    rows.push({
      key: "tokens",
      value: t("confirm.estimatedTokens", { count: confirmation.detail.estTokens }),
    });
    if (confirmation.detail.estCostUSD) {
      rows.push({
        key: "cost",
        value: t("confirm.estimatedCost", { cost: confirmation.detail.estCostUSD }),
      });
    }
  }

  return (
    <Dialog
      open={confirmation != null}
      onClose={() => resolveLibraryConfirmation("cancel")}
      ariaLabelledBy="library-confirmation-title"
      className={styles.dialog}
      initialFocusSelector={
        confirmation?.reason === "sensitive"
          ? "[data-library-confirm='redact']"
          : "[data-library-confirm='continue']"
      }
      lockBodyScroll
    >
      {/* Aurora at the top, in the same visual language as the library page: indigo top left,
          violet top right, dissolving downwards, instead of a flat dialog background. */}
      <div className={styles.aurora} aria-hidden="true" />
      <div className={styles.body}>
        <span className={styles.icon} data-tone={visual.tone} aria-hidden="true">
          <Icon size={26} strokeWidth={1.8} />
        </span>
        <h2 id="library-confirmation-title" className={styles.title}>
          {t(`confirm.${reason}.title`)}
        </h2>
        <p className={styles.message}>{t(`confirm.${reason}.message`)}</p>

        {rows.length > 0 ? (
          <dl className={styles.info}>
            {rows.map((row) => (
              <div key={row.key} className={styles.infoRow}>
                {row.label ? <dt>{row.label}</dt> : <dt aria-hidden="true" />}
                <dd>{row.value}</dd>
              </div>
            ))}
          </dl>
        ) : null}

        <div className={styles.actions}>
          <Button
            data-library-confirm="continue"
            className={styles.primaryAction}
            onClick={() => resolveLibraryConfirmation("continue")}
          >
            {t("confirm.continue")}
          </Button>
          {confirmation?.reason === "sensitive" ? (
            <Button
              data-library-confirm="redact"
              tone="secondary"
              onClick={() => resolveLibraryConfirmation("redact")}
            >
              {t("confirm.redact")}
            </Button>
          ) : null}
          {/* Cancel is the lightest of the three actions: no fill, no border, text only. */}
          <button
            type="button"
            className={styles.quietAction}
            onClick={() => resolveLibraryConfirmation("cancel")}
          >
            {t("confirm.cancel")}
          </button>
        </div>
      </div>
    </Dialog>
  );
}
