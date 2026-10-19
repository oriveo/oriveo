"use client";

import { useEffect, useState } from "react";
import { useLocale, useTranslations } from "next-intl";
import { Button, Dialog } from "@oriveo/ui";
import { useAppStore } from "../../providers/StoreProvider";
import { capConfirmTextOf } from "../../lib/core/chat/context-visibility/cap-confirm";
import { pendingCapConfirmationOf, resolveCapConfirmation } from "../../lib/core/chat/context-visibility/cap-confirm-gate";
import styles from "./ContextCapConfirmDialog.module.css";

/**
 * Confirmation dialog for exceeding the cap / the price-tier line before sending.
 * Shows only the entry pending for the current conversation; Esc / clicking the backdrop = cancel; initial focus is on Cancel, so Enter never lands on Send.
 */
export function ContextCapConfirmDialog({ conversationId }: { conversationId: string | null | undefined }) {
  const tCap = useTranslations("pages.chat.contextCap");
  const tCommon = useTranslations("common");
  const locale = useLocale();
  const request = useAppStore((state) => pendingCapConfirmationOf(state, conversationId));
  const requestId = request?.id ?? null;
  const [dontAsk, setDontAsk] = useState(false);

  // Every request starts unchecked.
  useEffect(() => {
    setDontAsk(false);
  }, [requestId]);

  const text = request
    ? capConfirmTextOf(
        request.decision,
        {
          estimatedInput: request.estimatedInput,
          B: request.B,
          priceLineTokens: request.priceLineTokens,
          modelName: request.modelName,
          locale,
        },
        tCap,
      )
    : null;

  const cancel = () => {
    if (request) resolveCapConfirmation(request.conversationId, { kind: "cancel" });
  };

  return (
    <Dialog
      open={text != null}
      onClose={cancel}
      ariaLabelledBy="context-cap-confirm-title"
      initialFocusSelector="[data-testid='context-confirm-cancel']"
      lockBodyScroll
    >
      {text ? (
        <div className={styles.body}>
          <h2 id="context-cap-confirm-title" className={styles.title}>
            {text.title}
          </h2>
          <p className={styles.message}>{text.body}</p>
          {text.showDontAsk && text.dontAsk ? (
            <label className={styles.dontAsk}>
              <input
                type="checkbox"
                data-testid="context-confirm-dont-ask"
                checked={dontAsk}
                onChange={(event) => setDontAsk(event.target.checked)}
              />
              <span>{text.dontAsk}</span>
            </label>
          ) : null}
          <div className={styles.actions}>
            <Button type="button" tone="secondary" data-testid="context-confirm-cancel" onClick={cancel}>
              {tCommon("cancel")}
            </Button>
            <Button
              type="button"
              data-testid="context-confirm-send"
              onClick={() => {
                if (request) resolveCapConfirmation(request.conversationId, { kind: "confirm", dontAsk: text.showDontAsk && dontAsk });
              }}
            >
              {text.confirm}
            </Button>
          </div>
        </div>
      ) : null}
    </Dialog>
  );
}
