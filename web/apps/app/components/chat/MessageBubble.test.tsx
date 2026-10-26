import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { makeRelayRequested, type ChatMessage, type Provider } from "@oriveo/shared";
import { MessageBubble } from "./MessageBubble";
import type { AIModel, Conversation } from "@oriveo/shared";
import { recordInputNegativeCache } from "../../lib/core/capability/input-negative-cache";
import enMessages from "../../messages/en.json";
import { inputNegativeCacheTarget, resolveInputCapabilityProjections } from "../../lib/core/capability/truth/input-truth-adapter";
import { createRelayManualModel } from "../../lib/core/provider-model-ops";
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from "../../lib/core/providers/capability-evidence-identity";
import { getActiveUIDSync } from "../../lib/infra/storage/partition";
import {
  USER_MESSAGE_FOLD_THRESHOLD,
  userMessagePreview,
} from "../../lib/core/chat/user-message-fold";

const {
  mockCreateModelDisplayLookup,
  mockPreviewFileAttachment,
  mockLoadFilePreviewUtils,
  mockShowToast,
} = vi.hoisted(() => ({
  mockCreateModelDisplayLookup: vi.fn(),
  mockPreviewFileAttachment: vi.fn(),
  mockLoadFilePreviewUtils: vi.fn(),
  mockShowToast: vi.fn(),
}));

const { mockRouterPush, mockRouterRefresh } = vi.hoisted(() => ({
  mockRouterPush: vi.fn(),
  mockRouterRefresh: vi.fn(),
}));

const { mockHandleContextMenu } = vi.hoisted(() => ({
  mockHandleContextMenu: vi.fn(),
}));

const { mockAcknowledgeManagedPrivacy } = vi.hoisted(() => ({
  mockAcknowledgeManagedPrivacy: vi.fn(),
}));

const libraryFeatureFlagMock = vi.hoisted(() => ({ enabled: true }));

vi.mock("../../lib/core/library/feature-flag", () => ({
  isLibraryFeatureEnabled: () => libraryFeatureFlagMock.enabled,
}));

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: mockRouterPush, refresh: mockRouterRefresh }),
}));

vi.mock("next-intl", () => ({
  useTranslations: () => (key: string) => key,
  // MessageMeta.tsx pulls in useLocale, so this mock has to provide it; without it the suite fails
  // with No "useLocale" export ... even though production is fine.
  useLocale: () => "en",
}));

vi.mock("@oriveo/config", () => ({
  getProviderDisplayName: () => "OpenAI",
}));

vi.mock("@oriveo/ui", () => ({
  FileIcon: () => <span data-testid="file-icon" />,
  // MessageTokenUsageDialog uses Dialog, so it needs a mock here too.
  // Shaped like the ones in ChatView.test.tsx and LibraryConfirmationDialog.test.tsx.
  Dialog: ({ open, children }: { open: boolean; children: React.ReactNode }) =>
    open ? <div role="dialog">{children}</div> : null,
  CloseButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
}));

vi.mock("../../lib/utils/format-utils", () => ({
  formatCost: () => null,
}));

vi.mock("./MarkdownRenderer", () => ({
  MarkdownRenderer: ({ content }: { content: string }) => <div>{content}</div>,
}));

vi.mock("./MessageActions", () => ({
  MessageActions: () => <div data-testid="message-actions" />,
}));

vi.mock("./TypingIndicator", () => ({
  TypingIndicator: () => <div data-testid="typing-indicator" />,
}));

vi.mock("./MessageRecoveryCard", () => ({
  MessageRecoveryCard: ({
    onRetry,
    onContinue,
    primaryActionLabel,
    onPrimaryAction,
    resendWithoutMedia,
    rejectionRecoveryLayout,
    onSwitchModel,
    onSwitchKey,
    errorTitle,
    errorDetail,
  }: {
    onSwitchKey?: () => void;
    resendWithoutMedia?: string;
    rejectionRecoveryLayout?: boolean;
    onSwitchModel?: () => void;
    errorTitle?: string;
    errorDetail?: string;
    onRetry?: () => void;
    onContinue?: () => void;
    primaryActionLabel?: string;
    onPrimaryAction?: () => void;
  }) => (
    <div
      data-testid="message-recovery-card"
      data-error-title={errorTitle}
      data-error-detail={errorDetail}
      data-rejection-recovery-layout={rejectionRecoveryLayout ? "true" : undefined}
    >
      {onRetry ? (
        <button type="button" onClick={onRetry}>
          regenerateBtn
        </button>
      ) : null}
      {onContinue ? (
        <button type="button" onClick={onContinue}>
          continueBtn
        </button>
      ) : null}
      {(primaryActionLabel ?? (resendWithoutMedia ? `resendWithout.${resendWithoutMedia}` : undefined)) && onPrimaryAction ? (
        <button type="button" onClick={onPrimaryAction}>
          {primaryActionLabel ?? `resendWithout.${resendWithoutMedia}`}
        </button>
      ) : null}
      {onSwitchModel ? (
        <button type="button" onClick={onSwitchModel}>
          mockSwitchModel
        </button>
      ) : null}
      {onSwitchKey ? (
        <button type="button" onClick={onSwitchKey}>
          mockSwitchKey
        </button>
      ) : null}
    </div>
  ),
}));

vi.mock("../ContextMenu", () => ({
  ContextMenu: () => null,
  useContextMenu: () => ({
    menu: null,
    handleContextMenu: mockHandleContextMenu,
    closeMenu: vi.fn(),
  }),
}));

vi.mock("../ProviderIcon", () => ({
  ProviderIcon: ({
    kind,
    size,
    bare,
  }: {
    kind: string;
    size?: number;
    bare?: boolean;
  }) => (
    <span
      data-testid="provider-icon"
      data-kind={kind}
      data-size={size ?? ""}
      data-bare={bare ? "true" : "false"}
    />
  ),
}));

vi.mock("../../lib/utils/file-preview-utils-lazy", () => ({
  loadFilePreviewUtils: mockLoadFilePreviewUtils,
}));

vi.mock("../../lib/hooks/useMessageEdit", () => ({
  useMessageEdit: () => ({
    editing: false,
    editText: "",
    setEditText: vi.fn(),
    handleStartEdit: vi.fn(),
    handleCancelEdit: vi.fn(),
    handleSubmitEdit: vi.fn(),
    handleEditKeyDown: vi.fn(),
  }),
}));

const mockSetPreferences = vi.fn();
let mockHasSeenNoteCaptureHint = false;

vi.mock("../../providers/StoreProvider", () => ({
  useAppStore: (
    selector: (state: {
      account: null;
      preferences: { hasSeenNoteCaptureHint?: boolean };
      setPreferences: ReturnType<typeof vi.fn>;
      conversations: unknown[];
      providers: unknown[];
    }) => unknown,
  ) =>
    selector({
      account: null,
      preferences: { hasSeenNoteCaptureHint: mockHasSeenNoteCaptureHint },
      setPreferences: mockSetPreferences,
      conversations: [],
      providers: [],
    }),
  getVanillaStore: () => ({ getState: () => ({}) }),
}));

vi.mock("../Toast", () => ({
  showToast: (...args: unknown[]) => mockShowToast(...args),
}));

vi.mock("./AttachmentImage", () => ({
  AttachmentImage: () => <div data-testid="attachment-image" />,
}));

vi.mock("../common/UserAvatar", () => ({
  UserAvatar: () => <div data-testid="user-avatar" />,
}));

vi.mock("../../lib/core/providers/model-display-lookup", () => ({
  createModelDisplayLookup: mockCreateModelDisplayLookup,
}));

const provider: Provider = {
  id: "provider-1",
  kind: "openAI",
  status: { kind: "connected" },
  models: [],
  catalogModels: [],
  apiKey: "sk-test",
  apiKeyPreview: "sk-...test",
};

const baseMessage: ChatMessage = {
  id: "message-1",
  role: "assistant",
  text: "Hello",
  providerID: "provider-1",
  providerKind: "openAI",
  providerName: "OpenAI",
  modelID: "gpt-4o-2024-08-06",
  modelName: "Persisted Model Name",
  state: "delivered",
  estimatedCost: 0,
};

const imageAttachment = {
  id: "attachment-1",
  kind: "image" as const,
  fileName: "image-01.png",
  mimeType: "image/png",
  base64Data: "ZmFrZQ==",
};

const fileAttachment = {
  id: "attachment-file-1",
  kind: "file" as const,
  fileName: "report.pdf",
  mimeType: "application/pdf",
  base64Data: "ZmFrZQ==",
};

describe("MessageBubble", () => {
  it("renders a sent QuoteContext snapshot with a distinct read-only presentation", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue({
        modelId: "gpt-4o",
        canonicalModelId: "gpt-4o",
        displayName: "GPT-4o",
      }),
    });
    const { container } = render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "user",
          text: "Continue this",
          quoteContext: {
            schemaVersion: 1,
            sourceMessageId: "deleted-source-still-viewable",
            sourceRole: "assistant",
            contentKind: "prose",
            leadingText: "before ",
            selectedText: "snapshot survives",
            trailingText: " after",
            contextTruncated: false,
          },
        }}
        provider={provider}
      />,
    );

    expect(container.querySelector('[data-presentation="sent"]')).not.toBeNull();
    expect(screen.getByRole("button", { name: /snapshot survives/ })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "quoteRemove" })).toBeNull();
  });

  beforeEach(() => {
    mockCreateModelDisplayLookup.mockReset();
    mockPreviewFileAttachment.mockReset();
    mockLoadFilePreviewUtils.mockReset();
    mockShowToast.mockReset();
    mockRouterPush.mockReset();
    mockRouterRefresh.mockReset();
    mockHandleContextMenu.mockReset();
    mockAcknowledgeManagedPrivacy.mockReset();
    mockAcknowledgeManagedPrivacy.mockResolvedValue({
      acknowledgedAt: "2026-05-12T00:00:00.000Z",
      clientAckVersion: "managed-privacy-v1",
    });
    mockSetPreferences.mockReset();
    mockHasSeenNoteCaptureHint = false;
    libraryFeatureFlagMock.enabled = true;
    mockLoadFilePreviewUtils.mockResolvedValue({
      previewFileAttachment: mockPreviewFileAttachment,
    });
  });

  it("uses model display lookup results for assistant metadata", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue({
        modelId: "gpt-4o",
        canonicalModelId: "gpt-4o",
        displayName: "GPT-4o Latest",
      }),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    expect(screen.getAllByText("GPT-4o Latest").length).toBeGreaterThan(0);
    expect(mockCreateModelDisplayLookup).toHaveBeenCalledWith(provider);
  });

  it("falls back to the persisted message model name when lookup returns nothing", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    expect(screen.getAllByText("Persisted Model Name").length).toBeGreaterThan(
      0,
    );
  });

  it("renders a compact single-image gallery for assistant generated images", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, attachments: [imageAttachment] }}
        provider={provider}
      />,
    );

    const gallery = screen.getByRole("list");
    expect(gallery.getAttribute("data-layout")).toBe("single");
    expect(screen.getAllByRole("listitem")).toHaveLength(1);
  });

  it("renders assistant generated images as a grid when there are multiple images", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          attachments: [
            imageAttachment,
            {
              ...imageAttachment,
              id: "attachment-2",
              fileName: "image-02.png",
            },
          ],
        }}
        provider={provider}
      />,
    );

    const gallery = screen.getByRole("list");
    expect(gallery.getAttribute("data-layout")).toBe("grid");
    expect(screen.getAllByRole("listitem")).toHaveLength(2);
  });

  it("renders only the assistant avatar as a provider badge", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(<MessageBubble message={baseMessage} provider={provider} />);

    const icons = screen.getAllByTestId("provider-icon");
    expect(icons).toHaveLength(1);

    expect(icons[0].getAttribute("data-kind")).toBe("openAI");
    expect(icons[0].getAttribute("data-size")).toBe("28");
    expect(icons[0].getAttribute("data-bare")).toBe("true");
  });

  it("shows the interrupted recovery card only when it is the conversation last message", () => {
    // The recovery card is only shown on the last message of a conversation, so stopping A and then sending B cannot let a continue on A overwrite B.
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    const { rerender } = render(
      <MessageBubble
        message={{ ...baseMessage, role: "assistant", state: "interrupted" }}
        provider={provider}
        onContinue={vi.fn()}
        isLastMessage
      />,
    );
    expect(screen.getByTestId("message-recovery-card")).toBeTruthy();

    // Once the conversation moves on and this is not the last message, the recovery card disappears, so continuing an interrupted message in the middle cannot delete what follows
    rerender(
      <MessageBubble
        message={{ ...baseMessage, role: "assistant", state: "interrupted" }}
        provider={provider}
        onContinue={vi.fn()}
        isLastMessage={false}
      />,
    );
    expect(screen.queryByTestId("message-recovery-card")).toBeNull();
  });

  // An interrupted answer has two ways forward and must offer both: regenerate throws the partial
  // away and asks again, continue extends it.
  it("offers both regenerate and continue on an interrupted assistant message", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "assistant",
          state: "interrupted",
        }}
        provider={provider}
        onContinue={vi.fn()}
        onRetry={vi.fn()}
        isLastMessage
      />,
    );

    expect(screen.getByRole("button", { name: "regenerateBtn" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "continueBtn" })).toBeTruthy();
  });

  it("does not duplicate the generating status in the assistant header", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, state: "generating", text: "" }}
        provider={provider}
        streamingText=""
      />,
    );

    expect(screen.getByText("Persisted Model Name")).toBeTruthy();
    expect(screen.getByTestId("typing-indicator")).toBeTruthy();
    expect(screen.queryByText("generating")).toBeNull();
  });

  it("removes delivered assistant regenerate affordances while another request is in flight", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        onRetry={vi.fn()}
        interactionLocked
      />,
    );

    expect(screen.queryByRole("button", { name: "retry" })).toBeNull();
  });

  it("shows assistant metadata actions as understandable labels instead of icon-only controls", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
        onRetry={vi.fn()}
      />,
    );

    const copyButton = screen.getByRole("button", { name: "copy" });
    expect(copyButton.getAttribute("aria-label")).toBe("copy");
    expect(
      screen.getByRole("button", { name: "saveAsNote" }).textContent,
    ).toContain("saveAsNote");
    expect(screen.getByRole("button", { name: "more" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "retry" })).toBeNull();
    expect(
      screen.queryByRole("button", { name: "crosscheckAction" }),
    ).toBeNull();
  });

  it("keeps the user message context menu scoped to copy, note, and edit actions", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{ ...baseMessage, role: "user", text: "Can you repeat that?" }}
        provider={provider}
        conversationId="conv-1"
        onEditAndResend={vi.fn()}
      />,
    );

    fireEvent.contextMenu(screen.getByRole("article"));

    const items = mockHandleContextMenu.mock.calls[0]?.[1] as
      Array<{ label: string }> | undefined;
    expect(items?.map((item) => item.label).slice(0, 2)).toEqual([
      "copy",
      "saveAsNote",
    ]);
    expect(items?.map((item) => item.label)).toEqual([
      "copy",
      "saveAsNote",
      "editAndResend",
    ]);
  });

  it("folds an overlong user message to a bounded prefix and reads the whole text in a dialog", async () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    const long = "هذا نص عربي طويل جدا. ".repeat(10_000);

    render(
      <MessageBubble
        message={{ ...baseMessage, role: "user", text: long }}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    const prose = document.querySelector('[data-quote-block="prose"]');
    expect(prose?.textContent).toBe(userMessagePreview(long));
    expect(screen.queryByTestId("user-message-full-text-dialog")).toBeNull();

    // Copying the message still copies the full text, not the prefix shown in the bubble.
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
    });
    fireEvent.contextMenu(screen.getByRole("article"));
    const items = mockHandleContextMenu.mock.calls.at(-1)?.[1] as
      Array<{ label: string; onAction: () => void }> | undefined;
    items?.find((item) => item.label === "copy")?.onAction();
    await vi.waitFor(() => expect(writeText).toHaveBeenCalledWith(long));

    fireEvent.click(screen.getByRole("button", { name: "showFullMessage" }));
    const dialog = screen.getByTestId("user-message-full-text-dialog");
    const chunks = Array.from(dialog.querySelectorAll("p")).map((p) => p.textContent);
    expect(chunks.length).toBeGreaterThan(50);
    expect(chunks.join("")).toBe(long);
  });

  it("keeps user messages at the fold threshold fully rendered", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });
    const text = "a".repeat(USER_MESSAGE_FOLD_THRESHOLD);

    render(
      <MessageBubble
        message={{ ...baseMessage, role: "user", text }}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    expect(document.querySelector('[data-quote-block="prose"]')?.textContent).toBe(text);
    expect(screen.queryByRole("button", { name: "showFullMessage" })).toBeNull();
  });

  it("does not open the whole-message context menu while text is selected inside the message", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "assistant",
          text: "Selected assistant answer",
        }}
        provider={provider}
        conversationId="conv-1"
        onRetry={vi.fn()}
      />,
    );

    const article = screen.getByRole("article");
    const getSelectionSpy = vi.spyOn(window, "getSelection").mockReturnValue({
      rangeCount: 1,
      isCollapsed: false,
      anchorNode: article,
      focusNode: article,
      toString: () => "Selected assistant answer",
    } as unknown as Selection);

    fireEvent.contextMenu(article);

    expect(mockHandleContextMenu).not.toHaveBeenCalled();
    getSelectionSpy.mockRestore();
  });

  it("shows the note capture hint the first time a delivered assistant answer can be saved", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    expect(mockShowToast).toHaveBeenCalledWith(
      "noteCaptureHint",
      4000,
      undefined,
      "success",
    );
    expect(mockSetPreferences).toHaveBeenCalledWith({
      hasSeenNoteCaptureHint: true,
    });
  });

  it("does not repeat the note capture hint after it has been seen", () => {
    mockHasSeenNoteCaptureHint = true;
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        conversationId="conv-1"
      />,
    );

    expect(mockShowToast).not.toHaveBeenCalled();
    expect(mockSetPreferences).not.toHaveBeenCalled();
  });

  it("loads file preview helpers lazily when opening a user attachment", async () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          role: "user",
          attachments: [fileAttachment],
        }}
        provider={provider}
      />,
    );

    screen.getByRole("button", { name: "report.pdf" }).click();

    expect(mockLoadFilePreviewUtils).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      expect(mockPreviewFileAttachment).toHaveBeenCalledWith(
        expect.objectContaining({ id: "attachment-file-1", kind: "file" }),
        expect.any(Function),
        expect.any(Function),
      );
    });
  });

  it("folds multiple saved notes into one badge with a dropdown that routes to note detail", () => {
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={baseMessage}
        provider={provider}
        savedNoteRefs={[
          { id: "note-1", title: "First saved note" },
          { id: "note-2", title: "Second saved note" },
        ]}
      />,
    );

    // Several notes collapse into one chip showing the first title plus "+1", with the dropdown closed by default
    const badge = screen.getByRole("button", { name: /First saved note/ });
    expect(badge.textContent).toContain("+1");
    expect(screen.queryByRole("menuitem")).toBeNull();

    // Open the dropdown, list every note, and click the second one to jump to its detail
    fireEvent.click(badge);
    fireEvent.click(
      screen.getByRole("menuitem", { name: /Second saved note/ }),
    );
    expect(mockRouterPush).toHaveBeenCalledWith("/notes/note-2");
  });

  it('offers a user-confirmed retry without custom fields without claiming a capability rejection', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const onRetryWithoutCustom = vi.fn();
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-custom-failure',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: 'ordinary provider failure',
          capabilityResults: [{ owner: 'generation', state: 'requested', source: 'custom', revision: 'runtime-r3' }],
          capabilityRecovery: {
            version: 1,
            action: 'user_confirmed_resend_without_located_setting',
            source: 'custom',
            owners: ['generation'],
            locatedPointers: [],
          },
        }}
        provider={provider}
        onRetryWithoutCustom={onRetryWithoutCustom}
        isLastMessage
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'resendWithoutSetting' }));
    expect(onRetryWithoutCustom).toHaveBeenCalledTimes(1);
  });

  // library_not_connected (never connected to any source) and needs_reauth offer the same action,
  // since for the user both mean the document source has to be reconnected before an answer can
  // be produced.
  it.each([
    ["library_needs_reauth"],
    ["library_not_connected"],
  ])(
    "offers a retry as the Library recovery action for %s",
    (errorKind) => {
      mockCreateModelDisplayLookup.mockReturnValue({
        resolve: vi.fn().mockReturnValue(null),
      });
      const onRetry = vi.fn();
      render(
        <MessageBubble
          message={{
            ...baseMessage,
            id: `assistant-${errorKind}`,
            state: "failed",
            errorTitle: "researchErrorTitle",
            errorDetail: "localized detail",
            errorKind,
          }}
          provider={provider}
          onRetry={onRetry}
          isLastMessage
        />,
      );

      fireEvent.click(screen.getByRole("button", { name: "error.retry" }));
      expect(onRetry).toHaveBeenCalledTimes(1);
    },
  );

  it("hides Library research metadata and recovery actions when the feature is disabled", () => {
    libraryFeatureFlagMock.enabled = false;
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          state: "failed",
          errorTitle: "researchErrorTitle",
          errorKind: "library_needs_reauth",
          researchSteps: [{
            tool: "library_search",
            label: "Roadmap",
            status: "completed",
          }],
          citations: [{
            url: "https://www.notion.so/roadmap",
            title: "Roadmap",
            source: "notion",
            docId: "roadmap",
          }],
        }}
        provider={provider}
        onRetry={vi.fn()}
        isLastMessage
      />,
    );

    expect(screen.queryByText("progress.complete")).toBeNull();
    expect(screen.queryByText("citationsLabel")).toBeNull();
    expect(screen.queryByText("disclaimer")).toBeNull();
    expect(screen.queryByRole("button", { name: "error.retry" })).toBeNull();
    expect(screen.getByTestId("message-recovery-card")).toBeTruthy();
  });

  it('upstream names one panel parameter as rejected: the title is that item, the body explains the way out, the upstream text is in the technical detail, and resending is triggered by a click', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const onRetryWithoutCustom = vi.fn();
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-generation-rejected',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: "Unsupported value: 'temperature'",
          errorSource: 'provider',
          errorTechnicalDetail: "Unsupported value: 'temperature'",
          generationParameterRejection: { parameterId: 'temperature' },
        }}
        provider={provider}
        onRetryWithoutCustom={onRetryWithoutCustom}
        isLastMessage
      />,
    );

    const card = screen.getByTestId('message-recovery-card');
    expect(card.getAttribute('data-error-title')).toBe('generationParameterNameTemperature');
    expect(card.getAttribute('data-error-detail')).toBe('capabilityControlUpstreamRejected');
    expect(onRetryWithoutCustom).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'resendWithoutSetting' }));
    expect(onRetryWithoutCustom).toHaveBeenCalledTimes(1);
  });

  it('signature names enable_search (not a panel parameter): the title uses the web-search capability copy, and en does not contain the raw parameter name', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-signature-param-rejected',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: 'This model does not support enable_search.',
          errorSource: 'provider',
          generationParameterRejection: { parameterId: 'enable_search' },
        }}
        provider={provider}
        onRetryWithoutCustom={vi.fn()}
        isLastMessage
      />,
    );
    const titleKey = screen.getByTestId('message-recovery-card').getAttribute('data-error-title')!;
    expect(titleKey).toBe('common.capabilityControlWebSearch');
    const en = enMessages as unknown as Record<string, unknown>;
    const enTitle = titleKey.split('.').reduce<unknown>((node, part) => (node as Record<string, unknown>)?.[part], en);
    expect(typeof enTitle).toBe('string');
    expect(enTitle).not.toContain('enable_search');
    expect(screen.getByRole('button', { name: 'resendWithoutSetting' })).toBeTruthy();
  });

  it('RL2-NEGCACHE-03 relay image rejected: the body says images are unsupported and the primary action is switching models', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const onSwitchModel = vi.fn();
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-relay-image-rejected',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: 'image_url is not supported',
          errorSource: 'provider',
          relayImageUnsupported: true,
        }}
        provider={provider}
        onSwitchModel={onSwitchModel}
        isLastMessage
      />,
    );

    const card = screen.getByTestId('message-recovery-card');
    expect(card.getAttribute('data-error-detail')).toBe('recovery.imageUnsupported');
    fireEvent.click(screen.getByRole('button', { name: 'recovery.switchModelBtn' }));
    expect(onSwitchModel).toHaveBeenCalledTimes(1);
  });

  it('BOARD-OPTIONS-11 relay file rejected and the fallback failed: the body says these files are unsupported and the primary action is switching models', () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const onSwitchModel = vi.fn();
    render(
      <MessageBubble
        message={{
          ...baseMessage,
          id: 'assistant-relay-file-rejected',
          state: 'failed',
          errorTitle: 'requestFailed.title',
          errorDetail: 'input_file is not supported',
          errorSource: 'provider',
          relayFileUnsupported: true,
        }}
        provider={provider}
        onSwitchModel={onSwitchModel}
        isLastMessage
      />,
    );

    const card = screen.getByTestId('message-recovery-card');
    expect(card.getAttribute('data-error-detail')).toBe('recovery.fileUnsupported');
    fireEvent.click(screen.getByRole('button', { name: 'recovery.switchModelBtn' }));
    expect(onSwitchModel).toHaveBeenCalledTimes(1);
  });

  it("keeps web search citations visible when the Library feature is disabled", () => {
    // The server defaults to library.enabled=false: web search sources (OpenRouter url_citation) must not be hidden along with Library.
    libraryFeatureFlagMock.enabled = false;
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });

    render(
      <MessageBubble
        message={{
          ...baseMessage,
          text: "Answer",
          citations: [
            { url: "https://apnews.com/", title: "AP News" },
            { url: "https://www.notion.so/roadmap", title: "Roadmap", source: "notion", docId: "roadmap" },
          ],
        }}
        provider={provider}
      />,
    );

    expect(screen.getByText("citationsLabel")).toBeTruthy();
    expect(screen.getByText("AP News")).toBeTruthy();
    expect(screen.queryByText("Roadmap")).toBeNull();
  });

  it("renders library_not_searched as a static Tool Call row", () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    render(
      <MessageBubble
        message={{ ...baseMessage, toolFallbackNotice: "library_not_searched" }}
        provider={provider}
      />,
    );

    const notice = screen.getByTestId("tool-fallback-notice");
    expect(notice.textContent).toContain("toolFallbackLibraryNotSearched");
    expect(notice.querySelector("button")).toBeNull();
    expect(notice.querySelector('[aria-expanded]')).toBeNull();
  });

  it("lets an unhandled tool card win over fallback notice and ignores web_recovered", () => {
    mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    const view = render(
      <MessageBubble
        message={{
          ...baseMessage,
          toolFallbackNotice: "library_not_searched",
          unhandledToolCalls: [{ id: "call-1", name: "weather", arguments: "{}" }],
        }}
        provider={provider}
      />,
    );

    expect(screen.getByTestId("unhandled-tool-call-card")).toBeTruthy();
    expect(screen.queryByTestId("tool-fallback-notice")).toBeNull();

    view.rerender(
      <MessageBubble
        message={{ ...baseMessage, toolFallbackNotice: "web_recovered" }}
        provider={provider}
      />,
    );
    expect(screen.queryByTestId("tool-fallback-notice")).toBeNull();
    expect(screen.queryByTestId("unhandled-tool-call-card")).toBeNull();
  });

  describe("upstream rejects images by signature", () => {
    const visionModel = (state: string, reasonCode?: string): AIModel => ({
      id: "vision-model", name: "Vision Model", capabilities: ["text"], transport: "openai_chat_completions",
      reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: "$",
      capabilityControls: {
        vision_input: { state, ...(reasonCode ? { reasonCode } : {}), wireFamily: "openai_chat.image_url" },
      },
    } as unknown as AIModel);
    const officialProvider = (model: AIModel): Provider => ({ ...provider, id: "official-1", models: [model] });
    const turnMessages = (model: AIModel): [ChatMessage, ChatMessage] => [
      { ...baseMessage, id: "u-1", role: "user", text: "look", modelID: model.id, providerID: "official-1",
        attachments: [imageAttachment] },
      { ...baseMessage, id: "a-1", text: "", modelID: model.id, providerID: "official-1", state: "failed",
        errorTitle: "Provider request failed", errorDetail: "Unexpected item type in content", errorSource: "provider" },
    ];

    beforeEach(() => {
      localStorage.clear();
      mockCreateModelDisplayLookup.mockReturnValue({ resolve: vi.fn().mockReturnValue(null) });
    });

    it.each([
      ["vision_input", "image"],
      ["file_input", "file"],
      ["video_input", "video"],
    ] as const)("a failed message that recorded %s as rejected by signature: the recovery card primary action is resending without %s, and only a click resends", (capabilityKey, media) => {
      const model = visionModel("unknown", "catalog_silent");
      const [user, failed] = turnMessages(model);
      const rejected: ChatMessage = { ...failed, inputRejection: { capabilityKey, signatureId: "test.signature" } };
      const onRetry = vi.fn();
      render(
        <MessageBubble
          message={rejected}
          provider={officialProvider(model)}
          conversation={{ id: "c-1", messages: [user, rejected] } as unknown as Conversation}
          onRetry={onRetry}
          isLastMessage
        />,
      );
      expect(onRetry).not.toHaveBeenCalled();
      fireEvent.click(screen.getByRole("button", { name: `resendWithout.${media}` }));
      expect(onRetry).toHaveBeenCalledTimes(1);
    });

    it.each([
      ["media", "resendWithout.image"],
      ["parameter", "resendWithoutSetting"],
    ] as const)("WEB-REJECTION-RECOVERY-byok_not_rate_limited_passes_switch_model (%s)", (kind, actionLabel) => {
      const model = visionModel("unknown", "catalog_silent");
      const [user, failed] = turnMessages(model);
      const rejected: ChatMessage = kind === "media"
        ? { ...failed, inputRejection: { capabilityKey: "vision_input", signatureId: "test.signature" } }
        : { ...failed, errorDetail: "Unsupported value: 'temperature'", generationParameterRejection: { parameterId: "temperature", signatureId: "test.signature" } };
      const onRetry = vi.fn();
      const onRetryWithoutCustom = vi.fn();
      const onSwitchModel = vi.fn();
      render(
        <MessageBubble
          message={rejected}
          provider={officialProvider(model)}
          conversation={{ id: "c-1", messages: [user, rejected] } as unknown as Conversation}
          onRetry={onRetry}
          onRetryWithoutCustom={onRetryWithoutCustom}
          onSwitchModel={onSwitchModel}
          isLastMessage
        />,
      );
      // BYOK, not rate limited: the card still receives the switch-model callback and the rejected one-tap action layout marker.
      expect(screen.getByTestId("message-recovery-card").getAttribute("data-rejection-recovery-layout")).toBe("true");
      fireEvent.click(screen.getByRole("button", { name: "mockSwitchModel" }));
      expect(onSwitchModel).toHaveBeenCalledTimes(1);
      fireEvent.click(screen.getByRole("button", { name: actionLabel }));
      expect(kind === "media" ? onRetry : onRetryWithoutCustom).toHaveBeenCalledTimes(1);
    });

    /** Relay with multiple keys, the current key rejected and an alternate available (same shape as the RelaySwitchKeyDialog fixture). */
    const relayMultiKeyProvider = (): Provider => {
      const requested = makeRelayRequested("openai_compatible");
      requested.authMode = "bearer";
      requested.transport = "openai_chat_completions";
      requested.resolvedAPIBaseURL = "https://api.myrelay.dev/v1";
      const userTransport = { relayTransport: "openai_chat_completions" as const, relayTransportSource: "user" as const };
      const relayModel = (id: string, extra: Partial<AIModel> = {}): AIModel => ({
        id, name: id, capabilities: ["text"], reasoningModeAvailable: false, isAvailable: true, isDefault: false,
        priceTier: "", ...extra,
      });
      return {
        id: "relay-switch-key",
        kind: "relay",
        customName: "myrelay.dev",
        status: { kind: "connected" },
        apiKey: "sk-a-0123456789abcdef",
        apiKeyPreview: "sk-a...cdef",
        baseURLText: "https://api.myrelay.dev",
        relayKind: "openai_compatible",
        relayRequested: requested,
        relayKeys: [
          { id: "initial", name: "OpenAI", apiKey: "", status: { state: "ok", httpStatus: 200 } },
          { id: "k-b", name: "Claude", apiKey: "sk-b-0123456789abcdef", status: { state: "invalid", httpStatus: 401 } },
        ],
        models: [relayModel("gpt-4o", { relayKeyID: "initial", relayDeniedKeyID: "initial", ...userTransport })],
        catalogModels: [relayModel("gpt-4o", { relayListedByKeyIDs: ["initial", "k-b"] })],
      } as Provider;
    };

    it("WEB-REJECTION-RECOVERY-panel_parameter_keeps_generic_layout", () => {
      // Generic panel-parameter verdict (stream-runner, no signature source) on a multi-key relay: no two-button layout, switch key is still offered.
      const relay = relayMultiKeyProvider();
      const failed: ChatMessage = {
        ...baseMessage, id: "a-relay", text: "", modelID: "gpt-4o", providerID: relay.id, state: "failed",
        errorTitle: "Provider request failed", errorDetail: "Unsupported value: 'temperature'", errorSource: "provider",
        generationParameterRejection: { parameterId: "temperature" },
      };
      const onRetryWithoutCustom = vi.fn();
      render(
        <MessageBubble
          message={failed}
          provider={relay}
          onRetry={vi.fn()}
          onRetryWithoutCustom={onRetryWithoutCustom}
          onSwitchModel={vi.fn()}
          isLastMessage
        />,
      );
      const card = screen.getByTestId("message-recovery-card");
      expect(card.getAttribute("data-rejection-recovery-layout")).toBeNull();
      expect(screen.getByRole("button", { name: "mockSwitchKey" })).toBeTruthy();
      // The original layout of non-rate-limited BYOK does not offer switch model.
      expect(screen.queryByRole("button", { name: "mockSwitchModel" })).toBeNull();
      fireEvent.click(screen.getByRole("button", { name: "resendWithoutSetting" }));
      expect(onRetryWithoutCustom).toHaveBeenCalledTimes(1);
    });

    it.each([
      ["relay_image_with_input_rejection", {
        relayImageUnsupported: true,
        inputRejection: { capabilityKey: "vision_input", signatureId: "test.signature" },
      }],
      // Custom fragment / additional body: even with a signature parameter recorded, the primary action stays each one's own exit, with no two-button layout.
      ["custom_fragment", {
        errorKind: "customRequestFieldsRejected",
        generationParameterRejection: { parameterId: "temperature", signatureId: "test.signature" },
      }],
      ["additional_body", {
        errorKind: "additionalBodyRejected",
        generationParameterRejection: { parameterId: "temperature", signatureId: "test.signature" },
      }],
      ["capability_recovery", {
        generationParameterRejection: { parameterId: "temperature", signatureId: "test.signature" },
        capabilityRecovery: {
          version: 1, action: "user_confirmed_resend_without_located_setting", source: "custom",
          owners: ["generation"], locatedPointers: [],
        },
      }],
    ] as const)("WEB-REJECTION-RECOVERY-no_two_button_layout_without_action (%s)", (_kind, extra) => {
      const model = visionModel("unknown", "catalog_silent");
      const [user, failed] = turnMessages(model);
      const message = { ...failed, ...extra } as unknown as ChatMessage;
      render(
        <MessageBubble
          message={message}
          provider={officialProvider(model)}
          conversation={{ id: "c-1", messages: [user, message] } as unknown as Conversation}
          onRetry={vi.fn()}
          onRetryWithoutCustom={vi.fn()}
          onSwitchModel={vi.fn()}
          isLastMessage
        />,
      );
      expect(screen.getByTestId("message-recovery-card").getAttribute("data-rejection-recovery-layout")).toBeNull();
    });

    it("only a negative cache (projection rejected_recently) and no rejection record on the failed message: no resend without images", () => {
      const model = visionModel("unknown", "catalog_silent");
      const official = officialProvider(model);
      // The production write entry records the rejection and the production facade reads the projection as rejected_recently; the action still trusts only the message's own record.
      const target = inputNegativeCacheTarget(official, model, undefined, "vision_input")!;
      recordInputNegativeCache(target.key, { signatureId: "dashscope.unexpected_item_type", verdictRevision: target.verdictRevision });
      expect(resolveInputCapabilityProjections(official, model, undefined)?.vision_input.disabledReason)
        .toBe("disabled.rejected_recently");
      const [user, failed] = turnMessages(model);
      render(
        <MessageBubble
          message={failed}
          provider={official}
          conversation={{ id: "c-1", messages: [user, failed] } as unknown as Conversation}
          onRetry={vi.fn()}
          isLastMessage
        />,
      );
      expect(screen.queryByRole("button", { name: "resendWithout.image" })).toBeNull();
    });

    it("no rejection record: no resend without images", () => {
      const model = visionModel("unknown", "catalog_silent");
      const [user, failed] = turnMessages(model);
      render(
        <MessageBubble
          message={failed}
          provider={officialProvider(model)}
          conversation={{ id: "c-1", messages: [user, failed] } as unknown as Conversation}
          onRetry={vi.fn()}
          isLastMessage
        />,
      );
      expect(screen.queryByRole("button", { name: "resendWithout.image" })).toBeNull();
    });

    it("an image in the user message that this model cannot receive (projected as placeholder): marked as not sent to this model", () => {
      const model = visionModel("unavailable", "model_capability_absent");
      const [user] = turnMessages(model);
      render(<MessageBubble message={user} provider={officialProvider(model)} />);
      expect(screen.getByText("bubbleNotSentToModel")).toBeTruthy();
    });

    it("an image the model can receive is not marked", () => {
      const model = visionModel("auto_available");
      const [user] = turnMessages(model);
      render(<MessageBubble message={user} provider={officialProvider(model)} />);
      expect(screen.queryByText("bubbleNotSentToModel")).toBeNull();
    });

    it("an image already sent in a Relay conversation (vision unknown, no caller send context): fill in the context before judging, not marked as unsent", () => {
      const requested = makeRelayRequested("openai_compatible");
      requested.authMode = "none";
      requested.securityMode = "local_http";
      requested.transport = "openai_chat_completions";
      requested.resolvedAPIBaseURL = "http://127.0.0.1:8080/v1";
      const model = createRelayManualModel("relay-vision-unknown");
      const relay = {
        ...provider, id: "relay-1", kind: "relay", models: [model], catalogModels: [model], apiKey: "", apiKeyPreview: "",
        baseURLText: "http://127.0.0.1:8080", relayKind: "openai_compatible", relayRequested: requested,
        relayResolvedBaseURLText: "http://127.0.0.1:8080/v1", relayResolvedTransport: "openai_chat_completions",
        relayResolvedAuthMode: "none",
      } as Provider;
      resetCapabilityEvidenceIdentitiesForTesting();
      beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), relay.id);
      try {
        const user: ChatMessage = { ...baseMessage, id: "u-relay", role: "user", text: "look", modelID: model.id,
          providerID: relay.id, providerKind: "relay", attachments: [imageAttachment] };
        render(<MessageBubble message={user} provider={relay} />);
        expect(screen.queryByText("bubbleNotSentToModel")).toBeNull();
      } finally {
        resetCapabilityEvidenceIdentitiesForTesting();
      }
    });
  });
});
