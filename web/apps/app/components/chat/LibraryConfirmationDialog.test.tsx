import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { LibraryConfirmationRequest } from "../../lib/core/library/types";
import { LibraryConfirmationDialog } from "./LibraryConfirmationDialog";

const mocks = vi.hoisted(() => ({
  confirmation: null as LibraryConfirmationRequest | null,
  resolve: vi.fn(),
}));

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values ? `${key}:${JSON.stringify(values)}` : key,
}));
vi.mock("../../providers/StoreProvider", () => ({
  useAppStore: (
    selector: (state: {
      libraryConfirmation: LibraryConfirmationRequest | null;
    }) => unknown,
  ) =>
    selector({
      libraryConfirmation: mocks.confirmation,
    }),
}));
vi.mock("../../lib/core/library/confirmation", () => ({
  resolveLibraryConfirmation: (choice: string) => mocks.resolve(choice),
}));
vi.mock("@oriveo/ui", () => ({
  Button: ({
    children,
    tone: _tone,
    ...props
  }: React.ButtonHTMLAttributes<HTMLButtonElement> & { tone?: string }) => (
    <button {...props}>{children}</button>
  ),
  Dialog: ({ open, children }: { open: boolean; children: React.ReactNode }) =>
    open ? <div>{children}</div> : null,
}));

afterEach(() => {
  mocks.confirmation = null;
  mocks.resolve.mockReset();
  cleanup();
});

describe("LibraryConfirmationDialog", () => {
  it("offers redaction only for sensitive content", () => {
    mocks.confirmation = { id: "sensitive-1", reason: "sensitive", detail: {} };
    render(<LibraryConfirmationDialog />);

    fireEvent.click(screen.getByText("confirm.redact"));
    expect(mocks.resolve).toHaveBeenCalledWith("redact");
  });

  it.each(["high_cost", "broad_read", "unknown_relay", "hosted_provider"] as const)(
    "does not offer redaction for %s confirmation",
    (reason) => {
      mocks.confirmation = { id: reason, reason, detail: {} };
      render(<LibraryConfirmationDialog />);

      expect(screen.queryByText("confirm.redact")).toBeNull();
      expect(screen.getByText("confirm.continue")).toBeTruthy();
    },
  );

  it("shows the preflight token and cost estimate", () => {
    mocks.confirmation = {
      id: "cost-1",
      reason: "high_cost",
      detail: { estTokens: 12_000, estCostUSD: "0.4200" },
    };
    render(<LibraryConfirmationDialog />);

    expect(screen.getByText(/confirm\.estimatedTokens/)).toBeTruthy();
    expect(screen.getByText(/confirm\.estimatedCost/)).toBeTruthy();
  });
});
