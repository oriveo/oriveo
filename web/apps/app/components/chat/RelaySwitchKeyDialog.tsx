"use client";

import { useId } from "react";
import { useTranslations } from "next-intl";
import type { Provider } from "@oriveo/shared";
import { relayKeyRows, relayModelKeyState, relayShowsKeyUI } from "@oriveo/shared/relay/relay-keys";
import { Button } from "@oriveo/ui";
import { applyRelayKeyOperation } from "../../lib/core/relay-model-probe-ops";
import { getVanillaStore } from "../../providers/StoreProvider";
import { relayKeyTitle } from "../../app/providers/[providerId]/relay-keys-board";
import styles from "../../app/providers/[providerId]/ProviderDetail.module.css";
import boardStyles from "../../app/providers/[providerId]/components/RelayDetailBoard.module.css";

export interface RelaySwitchKeyChoice {
  id: string;
  /** Name or mask. */
  title: string;
  preview: string;
}

/**
 * Candidates for chat "switch key": the model is still enabled, the currently effective key is denied (persisted
 * relayDeniedKeyID), and another key in the catalog lists it; only then is an alternate given. If any condition fails, null is returned (no button).
 */
export function relaySwitchKeyChoices(
  provider: Provider | undefined,
  modelID: string | undefined,
): RelaySwitchKeyChoice[] | null {
  if (!provider || provider.kind !== "relay" || !modelID || !relayShowsKeyUI(provider)) return null;
  if (!provider.models.some((model) => model.id === modelID)) return null;
  const state = relayModelKeyState(provider, modelID);
  if (!state.deniedOnCurrentKey || state.alternateKeyIDs.length === 0) return null;
  const rows = relayKeyRows(provider);
  return state.alternateKeyIDs.flatMap((id) => {
    const row = rows.find((item) => item.id === id);
    return row ? [{ id, title: relayKeyTitle(row), preview: row.preview }] : [];
  });
}

interface RelaySwitchKeyDialogProps {
  provider: Provider;
  modelID: string;
  modelName: string;
  onClose: () => void;
}

/** Choosing -> RK-2 rebind, close the panel; no automatic resend, the user taps the existing retry. */
export function RelaySwitchKeyDialog({ provider, modelID, modelName, onClose }: RelaySwitchKeyDialogProps) {
  const tr = useTranslations("pages.relayDetail");
  const tc = useTranslations("common");
  const titleId = useId();
  const choices = relaySwitchKeyChoices(provider, modelID) ?? [];

  // Choosing closes right away: the rebind is written synchronously, and the lazy verification afterwards runs in the background without waiting for it.
  const choose = (keyID: string) => {
    void applyRelayKeyOperation(getVanillaStore(), provider, { type: "rebind", modelID, keyID });
    onClose();
  };

  return (
    <div className={styles.confirmOverlay} onClick={onClose}>
      <div
        className={styles.confirmDialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onClick={(event) => event.stopPropagation()}
      >
        <div id={titleId} className={styles.confirmTitle}>{tr("chatSwitchKeyTitle", { model: modelName })}</div>
        <div className={styles.confirmDesc}>{tr("chatSwitchKeyHint")}</div>
        <div className={boardStyles.keyActions}>
          {choices.map((choice) => (
            <Button
              key={choice.id}
              tone="secondary"
              size="sm"
              onClick={() => choose(choice.id)}
            >
              {choice.title === choice.preview ? choice.title : `${choice.title} · ${choice.preview}`}
            </Button>
          ))}
        </div>
        <div className={styles.confirmActions}>
          <Button tone="secondary" size="sm" onClick={onClose}>{tc("cancel")}</Button>
        </div>
      </div>
    </div>
  );
}
