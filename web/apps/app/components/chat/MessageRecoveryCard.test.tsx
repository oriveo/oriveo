import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MessageRecoveryCard } from "./MessageRecoveryCard";

// Module-level translator constant: returning a new function on every call makes components that put t in their deps loop forever (it once pegged a worker).
vi.mock("next-intl", () => {
  const translate = (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;
  return { useTranslations: () => translate };
});

describe("MessageRecoveryCard", () => {
  it("renders continue (primary) and regenerate for interrupted messages", () => {
    const onRetry = vi.fn();
    const onContinue = vi.fn();

    render(
      <MessageRecoveryCard
        state="interrupted"
        onRetry={onRetry}
        onContinue={onContinue}
      />,
    );

    // The interrupted state keeps the partial so continuing stays reachable, instead of forcing a full re-answer that discards it
    const continueButton = screen.getByRole("button", { name: "continueBtn" });
    fireEvent.click(continueButton);
    expect(onContinue).toHaveBeenCalledTimes(1);

    const regenerateButton = screen.getByRole("button", {
      name: "regenerateBtn",
    });
    fireEvent.click(regenerateButton);
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it("disables regenerate while the conversation is already sending", () => {
    const onRetry = vi.fn();

    render(
      <MessageRecoveryCard state="interrupted" onRetry={onRetry} disabled />,
    );

    const regenerateButton = screen.getByRole("button", {
      name: "regenerateBtn",
    });
    expect(regenerateButton.getAttribute("disabled")).not.toBeNull();

    fireEvent.click(regenerateButton);

    expect(onRetry).not.toHaveBeenCalled();
  });

  it("uses a Library recovery action instead of retrying a non-recoverable error", () => {
    const onPrimaryAction = vi.fn();
    render(
      <MessageRecoveryCard
        state="failed"
        errorTitle="Library unavailable"
        errorDetail="Reconnect the source."
        primaryActionLabel="Open Library settings"
        onPrimaryAction={onPrimaryAction}
        onRetry={vi.fn()}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: "Open Library settings" }),
    );
    expect(onPrimaryAction).toHaveBeenCalledOnce();
    expect(screen.queryByRole("button", { name: "retryBtn" })).toBeNull();
  });

  // ── Localization at render time ─────────────────
  describe("render-time localization", () => {
    it("prefers the render-time copy over the language frozen at failure time", () => {
      render(
        <MessageRecoveryCard
          state="failed"
          // Persisted while the UI was in English, so the copy froze in English
          errorTitle="Rate limit exceeded"
          errorDetail="Too many requests."
          errorKind="rateLimited"
          errorDetailIsLocalized
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("rateLimited.title")).toBeTruthy();
      expect(screen.getByText("rateLimited.message")).toBeTruthy();
      expect(screen.queryByText("Rate limit exceeded")).toBeNull();
    });

    it("falls back to the stored strings for legacy messages without errorKind", () => {
      // The body appears both in the description and in the technical details section, so anchor the assertion to the description
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Balance Too Low"
          errorDetail="Add balance to continue."
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("Balance Too Low")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "Add balance to continue.",
      );
    });

    it("falls back to the stored strings for kinds outside the errors catalog (Library)", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Library needs reconnecting"
          errorDetail="Reconnect the source."
          errorKind="library_needs_reauth"
          onRetry={vi.fn()}
        />,
      );

      // Must not be overridden into a generic provider failure by the mapErrorKindKey upstream fallback
      expect(screen.getByText("Library needs reconnecting")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "Reconnect the source.",
      );
      expect(screen.queryByText("upstream.title")).toBeNull();
    });

    it("keeps the raw Server/SDK detail for non-managed failures while localizing the title", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Network Error"
          errorDetail="fetch failed: ECONNRESET"
          errorKind="network"
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("network.title")).toBeTruthy();
      // Raw upstream errors are not wrapped in a localized template
      expect(container.querySelector("p.description")?.textContent).toBe(
        "fetch failed: ECONNRESET",
      );
      expect(screen.queryByText("network.message")).toBeNull();
    });

    // The free tier returns OpenRouter's `429 | Provider returned error` verbatim, so that English string
    // ends up in the user-facing body, and the server rate-limit copy is a hardcoded string of its own.
    it("replaces Oriveo-owned technical text with localized copy and keeps the raw string for diagnosis", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Rate Limited"
          errorDetail="429 | Provider returned error"
          errorKind="rateLimited"
          errorSource="oriveo"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
          onSwitchModel={vi.fn()}
        />,
      );

      expect(screen.getByText("rateLimited.title")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "rateLimited.message",
      );
      // The original text is preserved, only demoted into the technical details section
      expect(screen.getByText("429 | Provider returned error")).toBeTruthy();
      // Both rate-limit ways out are still present
      expect(screen.getByRole("button", { name: "retryBtn" })).toBeTruthy();
      expect(screen.getByRole("button", { name: "switchModelBtn" })).toBeTruthy();
    });

    // Managed path with no network. After normalizing to network the body must read as a connection check,
    // not the engine's `Failed to fetch`.
    it("localizes a transport failure body instead of showing the raw engine wording", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Network Error"
          errorDetail="Failed to fetch"
          errorKind="network"
          errorSource="network"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
        />,
      );

      expect(screen.getByText("network.title")).toBeTruthy();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "network.message",
      );
      expect(screen.getByRole("button", { name: "retryBtn" })).toBeTruthy();
    });

    it("never localizes an upstream provider body away, even when asked", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Request Failed"
          errorDetail="engine_overloaded_error | The engine is currently overloaded"
          errorKind="rateLimited"
          errorSource="provider"
          detailIsInternalTechnicalText
          onRetry={vi.fn()}
        />,
      );

      // Provider text is the only source of truth for the body: copyKey is always null for source=provider,
      // so this case is unaffected by the new switch.
      expect(container.querySelector("p.description")?.textContent).toBe(
        "engine_overloaded_error | The engine is currently overloaded",
      );
    });

    it("does not rewrite a provider response title from its recovery kind", () => {
      const { container } = render(
        <MessageRecoveryCard
          state="failed"
          errorTitle="Request Failed"
          errorDetail="engine_overloaded_error | The engine is currently overloaded"
          errorKind="rateLimited"
          errorSource="provider"
          onRetry={vi.fn()}
          onSwitchModel={vi.fn()}
        />,
      );

      expect(screen.getByText("Request Failed")).toBeTruthy();
      expect(screen.queryByText("rateLimited.title")).toBeNull();
      expect(container.querySelector("p.description")?.textContent).toBe(
        "engine_overloaded_error | The engine is currently overloaded",
      );
      // kind still only drives the recovery action and never rewrites copy.
      expect(screen.getByRole("button", { name: "switchModelBtn" })).toBeTruthy();
    });
  });
});
