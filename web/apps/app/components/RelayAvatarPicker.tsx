"use client";

import { useId, useState } from "react";
import { useTranslations } from "next-intl";
import { Button, Dialog } from "@oriveo/ui";
import { useRelayAvatarChoice } from "../lib/hooks/useRelayAvatarChoice";
import { applyRelayAvatarPickerCell } from "../lib/core/providers/relay-avatar-choices";
import {
  RELAY_AVATAR_BRAND_DISPLAY_NAME,
  relayAvatarPickerCellMarker,
  relayAvatarPickerCells,
  relayAvatarPickerCellSelected,
  resolveRelayConnectionAvatar,
  type RelayAvatar as RelayAvatarValue,
  type RelayAvatarIconId,
  type RelayAvatarPickerCell,
  type RelayAvatarSource,
} from "./relay-avatar";
import { RelayAvatar } from "./RelayAvatar";
import styles from "./RelayAvatarPicker.module.css";

/** Icon cell label keys (listed statically so the string scanners can see them). */
const ICON_LABEL_KEYS: Record<RelayAvatarIconId, string> = {
  planet: "pages.relayDetail.avatarIcons.planet",
  compass: "pages.relayDetail.avatarIcons.compass",
  sailboat: "pages.relayDetail.avatarIcons.sailboat",
  lighthouse: "pages.relayDetail.avatarIcons.lighthouse",
  mountains: "pages.relayDetail.avatarIcons.mountains",
  "sun-horizon": "pages.relayDetail.avatarIcons.sunHorizon",
  flame: "pages.relayDetail.avatarIcons.flame",
  "tree-evergreen": "pages.relayDetail.avatarIcons.treeEvergreen",
  "moon-stars": "pages.relayDetail.avatarIcons.moonStars",
  butterfly: "pages.relayDetail.avatarIcons.butterfly",
};

const CHANGE_ICON_KEY = "pages.relayDetail.changeIcon";
const LETTER_LABEL_KEY = "pages.relayDetail.avatarLetter";

function cellAvatar(cell: RelayAvatarPickerCell): RelayAvatarValue {
  if (cell.kind === "brand") return { kind: "brand", brand: cell.brand };
  if (cell.kind === "letter") return { kind: "initial", text: cell.text };
  return { kind: "icon", icon: cell.icon };
}

/**
 * The detail header avatar is itself a button: it opens the "Change icon" sheet (brand cell? + ten icons + initial cell?, 4 columns).
 * Tapping a cell writes the on-device choice right away, and every place drawing this connection's avatar refreshes through the store subscription; Done closes it.
 */
export function RelayAvatarPickerButton({ source, size }: { source: RelayAvatarSource; size: number }) {
  const t = useTranslations();
  const titleId = useId();
  const [open, setOpen] = useState(false);
  const choice = useRelayAvatarChoice(source.providerId);
  const avatar = resolveRelayConnectionAvatar({
    providerId: source.providerId,
    name: source.name,
    baseURL: source.baseURL,
    choice,
  });
  const cells = relayAvatarPickerCells({ name: source.name, baseURL: source.baseURL });
  const label = (cell: RelayAvatarPickerCell) => {
    if (cell.kind === "brand") return RELAY_AVATAR_BRAND_DISPLAY_NAME[cell.brand];
    if (cell.kind === "letter") return t(LETTER_LABEL_KEY);
    return t(ICON_LABEL_KEYS[cell.icon]);
  };

  return (
    <>
      <button
        type="button"
        className={styles.trigger}
        onClick={() => setOpen(true)}
        aria-label={t(CHANGE_ICON_KEY)}
        title={t(CHANGE_ICON_KEY)}
        aria-haspopup="dialog"
      >
        <RelayAvatar avatar={avatar} size={size} />
      </button>
      <Dialog open={open} onClose={() => setOpen(false)} ariaLabelledBy={titleId}>
        <div className={styles.panel}>
          <div className={styles.panelHeader}>
            <h2 id={titleId} className={styles.panelTitle}>{t(CHANGE_ICON_KEY)}</h2>
            <Button type="button" tone="primary" size="sm" onClick={() => setOpen(false)}>
              {t("common.done")}
            </Button>
          </div>
          <div className={styles.grid}>
            {cells.map((cell) => {
              const marker = relayAvatarPickerCellMarker(cell);
              const text = label(cell);
              return (
                <button
                  key={marker}
                  type="button"
                  className={styles.cell}
                  data-relay-avatar-cell={marker}
                  aria-pressed={relayAvatarPickerCellSelected(cell, avatar)}
                  aria-label={text}
                  onClick={() => applyRelayAvatarPickerCell(source.providerId, cell)}
                >
                  <RelayAvatar avatar={cellAvatar(cell)} size={32} />
                  <span className={styles.cellLabel} aria-hidden="true">{text}</span>
                </button>
              );
            })}
          </div>
        </div>
      </Dialog>
    </>
  );
}
