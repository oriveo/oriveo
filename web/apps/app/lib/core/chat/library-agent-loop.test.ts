import { describe, expect, it, vi } from "vitest";
import type { StreamEvent, StreamHandle } from "@oriveo/core/providers/types";
import type { ProxyToolCall } from "@oriveo/core/providers/request-builders/runtime";
import { LibraryAPIError } from "../library/api";
import {
  DEFAULT_LIBRARY_RUNTIME_CONFIG,
  type LibraryReadResult,
} from "../library/types";
import {
	buildLibraryTools,
  LibraryAgentError,
  LibraryResearchCancelledError,
  runLibraryAgentLoop,
  type LibraryAgentLegRequest,
  type LibraryAgentLoopOptions,
} from "./library-agent-loop";
import { sendLibraryAgentLeg } from '../providers/proxy-client';
import {
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
} from './capability-recovery-runtime';

function streamLeg(events: StreamEvent[], abort = vi.fn()): StreamHandle {
  return {
    abort,
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
  };
}

function rejectionLeg(
  status: number,
  structuredError: unknown,
  events: StreamEvent[] = [{
    type: 'error',
    error: 'provider rejected request',
    source: 'provider',
    status,
  }],
): StreamHandle {
  return {
    ...streamLeg(events),
    getToolCallRejectionContext: () => ({ status, structuredError }),
  };
}

function hangingLeg(abortSpy = vi.fn()): StreamHandle {
  let streamController: ReadableStreamDefaultController<StreamEvent>;
  return {
    abort: () => {
      abortSpy();
      streamController.close();
    },
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        streamController = controller;
      },
    }),
  };
}

function callsEvent(...calls: ProxyToolCall[]): StreamEvent {
  return {
    type: "tool_calls",
    toolCalls: calls.map((call, index) => ({
      index,
      id: call.id,
      type: call.type,
      name: call.function.name,
      arguments: call.function.arguments,
    })),
  };
}

function call(
  id: string,
  name: string,
  args: Record<string, unknown>,
): ProxyToolCall {
  return {
    id,
    type: "function",
    function: { name, arguments: JSON.stringify(args) },
  };
}

function readResult(
  overrides: Partial<LibraryReadResult> = {},
): LibraryReadResult {
  return {
    docId: "doc-1",
    source: "notion",
    title: "Roadmap",
    url: "https://workspace.notion.so/doc-1",
    sections: [{ heading: "Plan", text: "Ship in August", anchor: "plan" }],
    sensitive: { hit: false },
    ...overrides,
  };
}

function options(
  overrides: Partial<LibraryAgentLoopOptions> = {},
): LibraryAgentLoopOptions {
  return {
    messages: [{ role: "user", content: "What is the plan?" }],
    config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 5 },
    signal: new AbortController().signal,
    runLeg: vi.fn(() => streamLeg([{ type: "delta", content: "No result." }])),
    executeTool: vi.fn(async () => ({ result: { hits: [] } })),
    requestConfirmation: vi.fn(async () => "continue" as const),
    ...overrides,
  };
}

describe("runLibraryAgentLoop", () => {
	it('resends the first pre-stream deterministic tools rejection exactly once without tools', async () => {
		const requests: LibraryAgentLegRequest[] = [];
		const result = await runLibraryAgentLoop(options({
			runLeg: (request) => {
				requests.push(request);
				return requests.length === 1
					? rejectionLeg(400, { error: { message: 'This model does not support tools' } })
					: streamLeg([{ type: 'delta', content: 'Fallback answer' }]);
			},
		}));

		expect(requests).toHaveLength(2);
		expect(requests[0]).toMatchObject({ toolChoice: 'auto' });
		expect(requests[0].tools).toHaveLength(3);
		expect(requests[1]).toEqual(expect.objectContaining({ tools: [], toolChoice: 'none' }));
		expect(result).toMatchObject({ text: 'Fallback answer', toolFallbackApplied: true });
	});

	it('covers the production request builder through rejection, retry, and the remembered next send', async () => {
		const localMemory = new Map<string, string>();
		vi.stubGlobal('localStorage', {
			getItem: (key: string) => localMemory.get(key) ?? null,
			setItem: (key: string, value: string) => localMemory.set(key, value),
		});
		const fetchMock = vi.spyOn(globalThis, 'fetch')
			.mockResolvedValueOnce(new Response(JSON.stringify({
				error: { message: 'This model does not support tools' },
			}), {
				status: 400,
				headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
			}))
			.mockImplementation(() => Promise.resolve(new Response(
				'data: {"choices":[{"delta":{"content":"Plain answer"}}]}\n\ndata: [DONE]\n\n',
				{ status: 200, headers: { 'Content-Type': 'text/event-stream' } },
			)));
		const runLeg: LibraryAgentLoopOptions['runLeg'] = ({ messages, tools, toolChoice }) =>
			sendLibraryAgentLeg('openAI', 'sk-test', 'gpt-4o', messages, tools, undefined, undefined, toolChoice);
		const first = await runLibraryAgentLoop(options({ runLeg }));
		const identity = {
			accountId: 'account-a', connectionId: 'connection-a', authMode: 'apiKey' as const,
			canonicalModelId: 'gpt-4o', finalTransport: 'openai_chat',
		};
		expect(first.toolFallbackApplied).toBe(true);
		recordToolCallSupportFalse(identity, 1_000);
		expect(toolCallSupportIsRememberedFalse(identity)).toBe(true);
		await runLibraryAgentLoop(options({
			runLeg,
			toolsEnabled: !toolCallSupportIsRememberedFalse(identity),
		}));

		const bodies = fetchMock.mock.calls.map((call) => JSON.parse(String((call[1] as RequestInit).body)) as Record<string, unknown>);
		expect(bodies).toHaveLength(3);
		expect(bodies[0].tools).toBeInstanceOf(Array);
		expect(bodies[0].toolChoice).toBe('auto');
		for (const body of bodies.slice(1)) {
			expect(body).not.toHaveProperty('tools');
			expect(body).not.toHaveProperty('toolChoice');
		}
		fetchMock.mockRestore();
		vi.unstubAllGlobals();
	});

	it.each([401, 403, 422, 429, 500])('does not resend an excluded HTTP %s', async (status) => {
		const runLeg = vi.fn(() => rejectionLeg(status, { error: { message: 'tools unsupported' } }));
		await expect(runLibraryAgentLoop(options({ runLeg }))).rejects.toBeInstanceOf(LibraryAgentError);
		expect(runLeg).toHaveBeenCalledOnce();
	});

	it('does not resend a network or timeout failure', async () => {
		const runLeg = vi.fn(() => streamLeg([{
			type: 'error', error: 'request timed out', errorKind: 'network', source: 'network',
		}]));
		await expect(runLibraryAgentLoop(options({ runLeg }))).rejects.toMatchObject({ source: 'network' });
		expect(runLeg).toHaveBeenCalledOnce();
	});

	it('does not recurse when the explicit no-tools resend also fails', async () => {
		const runLeg = vi.fn(() => rejectionLeg(400, {
			error: { message: 'This model does not support tools' },
		}));
		await expect(runLibraryAgentLoop(options({ runLeg }))).rejects.toBeInstanceOf(LibraryAgentError);
		expect(runLeg).toHaveBeenCalledTimes(2);
	});

	it('does not resend after the stream has started', async () => {
		const runLeg = vi.fn(() => rejectionLeg(400, { error: { message: 'tools unsupported' } }, [
			{ type: 'delta', content: 'partial' },
			{ type: 'error', error: 'rejected', source: 'provider', status: 400 },
		]));
		await expect(runLibraryAgentLoop(options({ runLeg }))).rejects.toMatchObject({ streamStarted: true });
		expect(runLeg).toHaveBeenCalledOnce();
	});

	it('does not resend a later-leg rejection after a tool side effect', async () => {
		let leg = 0;
		const runLeg = vi.fn(() => {
			leg += 1;
			return leg === 1
				? streamLeg([callsEvent(call('read-1', 'library_read', { source: 'notion', docId: 'doc-1' }))])
				: rejectionLeg(400, { error: { message: 'tools unsupported' } });
		});
		await expect(runLibraryAgentLoop(options({
			runLeg,
			executeTool: vi.fn(async () => ({ result: readResult() })),
		}))).rejects.toBeInstanceOf(LibraryAgentError);
		expect(runLeg).toHaveBeenCalledTimes(2);
	});

	it('starts directly without tools when the exact connection observation is false', async () => {
		const runLeg = vi.fn(() => streamLeg([{ type: 'delta', content: 'Plain answer' }]));
		const onFirstLegWithoutToolCalls = vi.fn();
		const result = await runLibraryAgentLoop(options({
			runLeg,
			toolsEnabled: false,
			onFirstLegWithoutToolCalls,
		}));
		expect(runLeg).toHaveBeenCalledWith(expect.objectContaining({ tools: [], toolChoice: 'none' }));
		expect(onFirstLegWithoutToolCalls).not.toHaveBeenCalled();
		expect(result.toolFallbackApplied).toBeUndefined();
	});

	it("preserves provider response ownership and recovery kind", async () => {
		await expect(
			runLibraryAgentLoop(
				options({
					runLeg: () => streamLeg([{
						type: "error",
						error: "The engine is overloaded",
						errorKind: "rateLimited",
						source: "provider",
					}]),
				}),
			),
		).rejects.toMatchObject({
			message: "The engine is overloaded",
			code: "rateLimited",
			source: "provider",
		});
	});

	it("limits every tool schema to currently active sources", () => {
		const tools = buildLibraryTools(DEFAULT_LIBRARY_RUNTIME_CONFIG, ["notion"]);
		for (const tool of tools) {
			const properties = tool.function.parameters.properties as Record<
				string,
				{ enum?: string[]; items?: { enum?: string[] } }
			>;
			const sourceEnum =
				properties.source?.enum ?? properties.sources?.items?.enum;
			expect(sourceEnum).toEqual(["notion"]);
		}
	});

	it("rejects a hallucinated call to a disconnected source", async () => {
		const executeTool = vi.fn();
		await expect(
			runLibraryAgentLoop(
				options({
					activeSources: ["notion"],
					config: {
						...DEFAULT_LIBRARY_RUNTIME_CONFIG,
						maxSelfCorrections: 0,
					},
					runLeg: () =>
						streamLeg([
							callsEvent(
								call("google-list", "library_list", { source: "google" }),
							),
						]),
					executeTool,
				}),
			),
		).rejects.toMatchObject({ code: "library_invalid_tool_call" });
		expect(executeTool).not.toHaveBeenCalled();
	});

  it("namespaces blank model tool-call IDs across research legs", async () => {
    const toolCallIds: string[] = [];
    const executeTool: LibraryAgentLoopOptions["executeTool"] = vi.fn(
      async (_tool, _args, toolCallId) => {
        toolCallIds.push(toolCallId);
        return { result: { items: [] } };
      },
    );
    let leg = 0;

    await runLibraryAgentLoop(
      options({
        runLeg: () => {
          leg += 1;
          if (leg <= 2) {
            return streamLeg([
              callsEvent(call(" ", "library_list", { source: "notion" })),
            ]);
          }
          return streamLeg([{ type: "delta", content: "Done" }]);
        },
        executeTool,
      }),
    );

    expect(toolCallIds).toEqual([
      "library_call_1_1",
      "library_call_2_1",
    ]);
  });

	it("emits progressive text snapshots for the final answer", async () => {
		const onText = vi.fn();
		const result = await runLibraryAgentLoop(
			options({
				onText,
				runLeg: () =>
					streamLeg([
						{ type: "delta", content: "Answer" },
						{ type: "delta", content: " [1]" },
					]),
			}),
		);
		expect(result.text).toBe("Answer [1]");
		expect(onText.mock.calls.map(([text]) => text)).toEqual([
			"Answer",
			"Answer [1]",
		]);
	});

  it("executes multiple tool calls from one leg and returns only referenced citations", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const runLeg = vi.fn((request: LibraryAgentLegRequest) => {
      requests.push(request);
      if (requests.length === 1) {
        return streamLeg([
          callsEvent(
            call("search-1", "library_search", { query: "roadmap" }),
            call("read-1", "library_read", {
              source: "notion",
              docId: "doc-1",
            }),
          ),
        ]);
      }
      return streamLeg([
        { type: "delta", content: "The launch is in August [1] [99]." },
      ]);
    });
    const executeTool: LibraryAgentLoopOptions["executeTool"] = vi.fn(
      async (tool) =>
        tool === "library_search"
          ? {
              result: {
                hits: [
                  {
                    docId: "doc-1",
                    source: "notion" as const,
                    title: "Roadmap",
                    url: "https://workspace.notion.so/doc-1",
                  },
                ],
              },
            }
          : { result: readResult() },
    );

    const result = await runLibraryAgentLoop(options({ runLeg, executeTool }));

    expect(executeTool).toHaveBeenCalledTimes(2);
    expect(result.citations).toEqual([
      expect.objectContaining({ index: 1, docId: "doc-1" }),
    ]);
    // A citation only carries document identity: the text snippet and the section anchor belong to this request and are never persisted or synced.
    expect(result.citations[0]?.snippet).toBeUndefined();
    expect(result.citations[0]?.anchor).toBeUndefined();
    const toolMessages = requests[1].messages.filter(
      (message) => message.role === "tool",
    );
    expect(toolMessages).toHaveLength(2);
    expect(
      JSON.parse(toolMessages[1].content as string).result.citationIndex,
    ).toBe(1);
  });

  it("reuses a stable citationIndex when the same document is read again", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const runLeg = vi.fn((request: LibraryAgentLegRequest) => {
      requests.push(request);
      if (requests.length <= 2) {
        return streamLeg([
          callsEvent(
            call(`read-${requests.length}`, "library_read", {
              source: "notion",
              docId: "doc-1",
              section: `part-${requests.length}`,
            }),
          ),
        ]);
      }
      return streamLeg([{ type: "delta", content: "Answer [1]." }]);
    });

    const result = await runLibraryAgentLoop(
      options({
        runLeg,
        executeTool: vi.fn(async () => ({ result: readResult() })),
      }),
    );

    expect(result.citations).toHaveLength(1);
    const secondReadPayload = JSON.parse(
      requests[2].messages.at(-1)?.content as string,
    );
    expect(secondReadPayload.result.citationIndex).toBe(1);
  });

  it("waits for sensitive confirmation and redacts only matching values before model reinjection", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    let resolveConfirmation!: (choice: "redact") => void;
    const confirmation = new Promise<"redact">((resolve) => {
      resolveConfirmation = resolve;
    });
    const runLeg = vi.fn((request: LibraryAgentLegRequest) => {
      requests.push(request);
      return requests.length === 1
        ? streamLeg([
            callsEvent(
              call("read-1", "library_read", {
                source: "notion",
                docId: "doc-1",
              }),
            ),
          ])
        : streamLeg([{ type: "delta", content: "Done [1]." }]);
    });
    const requestConfirmation = vi.fn(() => confirmation);
    const pending = runLibraryAgentLoop(
      options({
        runLeg,
        executeTool: vi.fn(async () => ({
          result: readResult({
            title: "Roadmap secret_abcdefghijklmnop",
            sensitive: { hit: true, kinds: ["secret", "pii"] },
            sections: [
              {
                heading: "Cloud AKIA1234567890ABCDEF",
                text: [
                  "Keep this sentence.",
                  "API key = sk-verysecret12345, email a@b.com, phone +1 (415) 555-0123.",
                  "Notion ntn_abcdefghijklmnop and deploy dop_v1_abcdefghijklmnop.",
                  "secret = 0123456789abcdef0123456789abcdef and token = QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo12345=",
                  "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----",
                ].join(" "),
              },
            ],
            redacted: {
              title: "Roadmap [REDACTED_SECRET]",
              sections: [
                {
                  heading: "Cloud [REDACTED_SECRET]",
                  text: "Keep this sentence. [REDACTED_SECRET] [REDACTED_PII]",
                },
              ],
            },
          }),
        })),
        requestConfirmation,
      }),
    );

    await vi.waitFor(() => expect(requestConfirmation).toHaveBeenCalledOnce());
    expect(requests).toHaveLength(1);
    expect(JSON.stringify(requests)).not.toContain("sk-verysecret12345");
    expect(requestConfirmation).toHaveBeenCalledWith(
      expect.objectContaining({
        detail: expect.objectContaining({
          docTitles: ["Roadmap [REDACTED_SECRET]"],
        }),
      }),
    );
    resolveConfirmation("redact");
    await pending;

    const payload = JSON.parse(requests[1].messages.at(-1)?.content as string);
    expect(payload.result.title).toBe("Roadmap [REDACTED_SECRET]");
    expect(payload.result.sections[0].heading).toBe("Cloud [REDACTED_SECRET]");
    expect(payload.result.sections[0].text).toContain("Keep this sentence.");
    for (const secret of [
      "sk-verysecret12345",
      "a@b.com",
      "555-0123",
      "ntn_abcdefghijklmnop",
      "dop_v1_abcdefghijklmnop",
      "0123456789abcdef0123456789abcdef",
      "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo12345=",
      "private-material",
    ]) {
      expect(JSON.stringify(payload.result)).not.toContain(secret);
    }
  });

  it("reinjects sensitive text only after continue and rejects cancel without reinjection", async () => {
    const sensitive = readResult({
      sensitive: { hit: true },
      sections: [{ text: "password: swordfish" }],
      redacted: {
        title: "Roadmap",
        sections: [{ text: "password: [REDACTED_CRED]" }],
      },
    });
    const continueRequests: LibraryAgentLegRequest[] = [];
    await runLibraryAgentLoop(
      options({
        runLeg: vi.fn((request) => {
          continueRequests.push(request);
          return continueRequests.length === 1
            ? streamLeg([
                callsEvent(
                  call("read-1", "library_read", {
                    source: "notion",
                    docId: "doc-1",
                  }),
                ),
              ])
            : streamLeg([{ type: "delta", content: "Done." }]);
        }),
        executeTool: vi.fn(async () => ({ result: sensitive })),
        requestConfirmation: vi.fn(async () => "continue" as const),
      }),
    );
    expect(JSON.stringify(continueRequests[1])).toContain("swordfish");

    const cancelRunLeg = vi.fn(() =>
      streamLeg([
        callsEvent(
          call("read-1", "library_read", { source: "notion", docId: "doc-1" }),
        ),
      ]),
    );
    await expect(
      runLibraryAgentLoop(
        options({
          runLeg: cancelRunLeg,
          executeTool: vi.fn(async () => ({ result: sensitive })),
          requestConfirmation: vi.fn(async () => "cancel" as const),
        }),
      ),
    ).rejects.toBeInstanceOf(LibraryResearchCancelledError);
    expect(cancelRunLeg).toHaveBeenCalledTimes(1);
  });

  it("fails closed when a sensitive response omits the server-redacted payload", async () => {
    const requestConfirmation = vi.fn(async () => "redact" as const);
    await expect(
      runLibraryAgentLoop(
        options({
          runLeg: vi.fn(() =>
            streamLeg([
              callsEvent(
                call("read-1", "library_read", {
                  source: "notion",
                  docId: "doc-1",
                }),
              ),
            ]),
          ),
          executeTool: vi.fn(async () => ({
            result: readResult({
              sensitive: { hit: true, kinds: ["secret"] },
              sections: [{ text: "key=0123456789abcdef0123456789abcdef" }],
            }),
          })),
          requestConfirmation,
        }),
      ),
    ).rejects.toMatchObject({ code: "library_redaction_unavailable" });
    expect(requestConfirmation).not.toHaveBeenCalled();
  });

  it("forces synthesis exactly at maxEmptyHits and does not permit another tool leg", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const result = await runLibraryAgentLoop(
      options({
        config: {
          ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
          maxEmptyHits: 1,
          maxSteps: 5,
        },
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("search-1", "library_search", { query: "missing" }),
                ),
              ])
            : streamLeg([
                {
                  type: "delta",
                  content: "I could not find relevant evidence.",
                },
              ]);
        }),
        executeTool: vi.fn(async () => ({ result: { hits: [] } })),
      }),
    );

    expect(result.text).toContain("could not find");
    expect(requests.map((request) => request.toolChoice)).toEqual([
      "auto",
      "none",
    ]);
  });

  it("requires library_list after an empty search and self-corrects an invalid next tool", async () => {
    const tools: string[] = [];
    let leg = 0;
    const result = await runLibraryAgentLoop(
      options({
        config: {
          ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
          maxEmptyHits: 3,
          maxSteps: 5,
        },
        runLeg: vi.fn(() => {
          leg += 1;
          if (leg === 1)
            return streamLeg([
              callsEvent(
                call("search-1", "library_search", { query: "missing" }),
              ),
            ]);
          if (leg === 2)
            return streamLeg([
              callsEvent(
                call("read-1", "library_read", {
                  source: "notion",
                  docId: "doc-1",
                }),
              ),
            ]);
          if (leg === 3)
            return streamLeg([
              callsEvent(call("list-1", "library_list", { source: "notion" })),
            ]);
          return streamLeg([{ type: "delta", content: "Nothing matched." }]);
        }),
        executeTool: vi.fn(async (tool) => {
          tools.push(tool);
          return tool === "library_search"
            ? { result: { hits: [] } }
            : { result: { items: [] } };
        }),
      }),
    );

    expect(result.text).toBe("Nothing matched.");
    expect(tools).toEqual(["library_search", "library_list"]);
  });

  it("feeds library_not_found back to the model instead of failing the chat", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const result = await runLibraryAgentLoop(
      options({
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("read-missing", "library_read", {
                    source: "notion",
                    docId: "missing",
                  }),
                ),
              ])
            : streamLeg([
                { type: "delta", content: "That document was not found." },
              ]);
        }),
        executeTool: vi.fn(async () => {
          throw new LibraryAPIError("not found", 404, "library_not_found");
        }),
      }),
    );

    expect(result.text).toContain("not found");
    expect(JSON.stringify(requests[1].messages)).toContain("library_not_found");
    // This step genuinely failed to read any evidence, so it is recorded as failed rather than completed.
    expect(result.steps).toEqual([
      expect.objectContaining({ status: "failed" }),
    ]);
  });

  // A non-fatal tool failure (an upstream 502, for example) degrades into an ok:false tool result
  // and the search continues, instead of blowing up the whole round.
  it("degrades a non-fatal tool failure other than library_not_found into an ok:false tool result and keeps searching", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const executeTool = vi.fn(async () => {
      throw new LibraryAPIError("source unavailable", 502, "library_source_error");
    });
    const result = await runLibraryAgentLoop(
      options({
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(call("list-1", "library_list", { source: "notion" })),
              ])
            : streamLeg([
                { type: "delta", content: "Answered without that source." },
              ]);
        }),
        executeTool,
      }),
    );

    expect(result.text).toBe("Answered without that source.");
    expect(executeTool).toHaveBeenCalledOnce();
    expect(JSON.stringify(requests[1].messages)).toContain("library_source_error");
  });

  // A fatal error (reauthorization required, monthly quota exhausted, the hard step ceiling, or a
  // missing redacted payload) holds for every subsequent call, so it is thrown immediately and
  // never counted as a degradation.
  it("throws immediately on a fatal tool failure that requires reauthorization, without counting it as a degradation", async () => {
    const executeTool = vi.fn(async () => {
      throw new LibraryAPIError("reauth needed", 401, "library_needs_reauth");
    });
    await expect(
      runLibraryAgentLoop(
        options({
          runLeg: vi.fn(() =>
            streamLeg([
              callsEvent(call("list-1", "library_list", { source: "notion" })),
            ]),
          ),
          executeTool,
        }),
      ),
    ).rejects.toMatchObject({ code: "library_needs_reauth" });
    expect(executeTool).toHaveBeenCalledOnce();
  });

  it("throws after three consecutive non-fatal tool failures instead of degrading forever", async () => {
    const executeTool = vi.fn(async () => {
      throw new LibraryAPIError("source flaky", 502, "library_source_error");
    });
    await expect(
      runLibraryAgentLoop(
        options({
          config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 10 },
          runLeg: vi.fn(() =>
            streamLeg([
              callsEvent(
                call("list-1", "library_list", { source: "notion" }),
                call("list-2", "library_list", { source: "notion" }),
                call("list-3", "library_list", { source: "notion" }),
              ),
            ]),
          ),
          executeTool,
        }),
      ),
    ).rejects.toMatchObject({ code: "library_source_error" });
    expect(executeTool).toHaveBeenCalledTimes(3);
  });

  it("resets the consecutive failure count on a successful execution", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    let attempt = 0;
    const executeTool = vi.fn(async () => {
      attempt += 1;
      if (attempt === 3) return { result: { items: [] } };
      throw new LibraryAPIError("source flaky", 502, "library_source_error");
    });
    const result = await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 10 },
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("list-1", "library_list", { source: "notion" }),
                  call("list-2", "library_list", { source: "notion" }),
                  call("list-3", "library_list", { source: "notion" }),
                  call("list-4", "library_list", { source: "notion" }),
                  call("list-5", "library_list", { source: "notion" }),
                ),
              ])
            : streamLeg([
                {
                  type: "delta",
                  content: "Completed despite intermittent failures.",
                },
              ]);
        }),
        executeTool,
      }),
    );

    expect(executeTool).toHaveBeenCalledTimes(5);
    expect(result.text).toBe("Completed despite intermittent failures.");
  });

  it("does not retry monthly quota exhaustion as a transient rate limit", async () => {
    const onQuota = vi.fn();
    const executeTool = vi.fn(async () => {
      throw new LibraryAPIError(
        "quota exhausted",
        429,
        "library_quota_exceeded",
        5,
        {
          used: 20,
          limit: 20,
          remaining: 0,
        },
      );
    });
    await expect(
      runLibraryAgentLoop(
        options({
          runLeg: vi.fn(() =>
            streamLeg([
              callsEvent(call("list-1", "library_list", { source: "notion" })),
            ]),
          ),
          executeTool,
          onQuota,
        }),
      ),
    ).rejects.toMatchObject({ code: "library_quota_exceeded" });
    expect(executeTool).toHaveBeenCalledOnce();
    expect(onQuota).toHaveBeenCalledWith({ used: 20, limit: 20, remaining: 0 });
  });

  it("enforces the invalid tool self-correction limit", async () => {
    await expect(
      runLibraryAgentLoop(
        options({
          config: {
            ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
            maxSelfCorrections: 1,
            maxSteps: 4,
          },
          runLeg: vi.fn(() =>
            streamLeg([callsEvent(call("bad", "delete_everything", {}))]),
          ),
        }),
      ),
    ).rejects.toMatchObject({
      code: "library_invalid_tool_call",
    } satisfies Partial<LibraryAgentError>);
  });

  it("forces a no-tool final leg at maxSteps and accumulates usage across every leg", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const onUsage = vi.fn();
    const result = await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 1 },
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("list-1", "library_list", { source: "notion" }),
                ),
                {
                  type: "usage",
                  usage: {
                    prompt_tokens: 10,
                    completion_tokens: 2,
                    total_tokens: 12,
                    breakdown: {
                      promptTokens: 8,
                      cachedInputTokens: 2,
                      cacheCreation5mTokens: 0,
                      cacheCreation1hTokens: 0,
                      completionTokens: 2,
                      reasoningTokens: 1,
                    },
                  },
                },
              ])
            : streamLeg([
                { type: "delta", content: "Final." },
                {
                  type: "usage",
                  usage: {
                    prompt_tokens: 20,
                    completion_tokens: 4,
                    total_tokens: 24,
                    breakdown: {
                      promptTokens: 20,
                      cachedInputTokens: 0,
                      cacheCreation5mTokens: 0,
                      cacheCreation1hTokens: 0,
                      completionTokens: 4,
                      reasoningTokens: 2,
                    },
                  },
                },
              ]);
        }),
        executeTool: vi.fn(async () => ({ result: { items: [] } })),
        onUsage,
      }),
    );

    expect(requests.map((request) => request.toolChoice)).toEqual([
      "auto",
      "none",
    ]);
    expect(result.usage).toMatchObject({
      prompt_tokens: 30,
      completion_tokens: 6,
      total_tokens: 36,
    });
    expect(result.usage?.breakdown).toMatchObject({
      promptTokens: 28,
      cachedInputTokens: 2,
      completionTokens: 6,
      reasoningTokens: 3,
    });
    expect(onUsage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ total_tokens: 12 }),
    );
    expect(onUsage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ total_tokens: 36 }),
    );
  });

  // A zero explicitly reported by upstream must be shown as zero. Every leg of a multi-leg search
  // dutifully returns cached_tokens: 0 with the observability flag set, and if merging drops that
  // flag both sides of `cacheReadObserved || cachedInputTokens > 0` in deriveCostFields go false,
  // the cache row disappears entirely, and "no cache hit this time" reads as "upstream reported
  // nothing".
  it("keeps cache observability flags when accumulating usage across legs", async () => {
    const observedZero = (promptTokens: number) => ({
      type: "usage" as const,
      usage: {
        prompt_tokens: promptTokens,
        completion_tokens: 2,
        total_tokens: promptTokens + 2,
        breakdown: {
          promptTokens,
          cachedInputTokens: 0,
          cacheCreation5mTokens: 0,
          cacheCreation1hTokens: 0,
          completionTokens: 2,
          reasoningTokens: 0,
          cacheReadObserved: true,
        },
      },
    });

    const requests: LibraryAgentLegRequest[] = [];
    const result = await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 1 },
        runLeg: vi.fn(() => {
          requests.push({} as LibraryAgentLegRequest);
          return requests.length === 1
            ? streamLeg([
                callsEvent(call("list-1", "library_list", { source: "notion" })),
                observedZero(10),
              ])
            : streamLeg([{ type: "delta", content: "Final." }, observedZero(20)]);
        }),
        executeTool: vi.fn(async () => ({ result: { items: [] } })),
      }),
    );

    expect(result.usage?.breakdown).toMatchObject({
      cachedInputTokens: 0,
      // Dropping this key would make it undefined and the cache row would disappear.
      cacheReadObserved: true,
    });
  });

  it("caps total tool executions across parallel calls and keeps step history valid", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const executeTool = vi.fn(async () => ({ result: { items: [] } }));
    const result = await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, maxSteps: 2 },
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("list-1", "library_list", { source: "notion" }),
                  call("list-2", "library_list", { source: "notion" }),
                  call("list-3", "library_list", { source: "notion" }),
                ),
              ])
            : streamLeg([{ type: "delta", content: "Final." }]);
        }),
        executeTool,
      }),
    );

    expect(executeTool).toHaveBeenCalledTimes(2);
    expect(result.steps.map((step) => step.step)).toEqual([1, 2]);
    expect(result.steps.map((step) => step.id)).toEqual([
      "1:list-1",
      "2:list-2",
    ]);
    expect(requests.map((request) => request.toolChoice)).toEqual([
      "auto",
      "none",
    ]);
    expect(requests[1].messages).toContainEqual(
      expect.objectContaining({
        role: "tool",
        tool_call_id: "list-3",
        content: expect.stringContaining("research_stopped"),
      }),
    );
  });

  it("stops tool execution at the configured token budget and preserves valid tool-call history", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const executeTool = vi.fn();
    const result = await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, tokenBudget: 12 },
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("list-1", "library_list", { source: "notion" }),
                ),
                {
                  type: "usage",
                  usage: {
                    prompt_tokens: 10,
                    completion_tokens: 2,
                    total_tokens: 12,
                  },
                },
              ])
            : streamLeg([
                { type: "delta", content: "There is not enough evidence." },
              ]);
        }),
        executeTool,
      }),
    );

    expect(executeTool).not.toHaveBeenCalled();
    expect(requests.map((request) => request.toolChoice)).toEqual([
      "auto",
      "none",
    ]);
    expect(requests[1].messages).toContainEqual(
      expect.objectContaining({
        role: "tool",
        tool_call_id: "list-1",
        content: expect.stringContaining("research_stopped"),
      }),
    );
    expect(result.text).toContain("not enough evidence");
  });

  it("derives a zero token budget from the current model context length", async () => {
    const requests: LibraryAgentLegRequest[] = [];
    const executeTool = vi.fn();
    await runLibraryAgentLoop(
      options({
        config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, tokenBudget: 0 },
        modelContextLength: 10,
        runLeg: vi.fn((request) => {
          requests.push(request);
          return requests.length === 1
            ? streamLeg([
                callsEvent(
                  call("list-1", "library_list", { source: "notion" }),
                ),
                {
                  type: "usage",
                  usage: { prompt_tokens: 8, completion_tokens: 2 },
                },
              ])
            : streamLeg([{ type: "delta", content: "Final." }]);
        }),
        executeTool,
      }),
    );

    expect(executeTool).not.toHaveBeenCalled();
    expect(requests.map((request) => request.toolChoice)).toEqual([
      "auto",
      "none",
    ]);
  });

  it("aborts a pending model stream", async () => {
    const controller = new AbortController();
    const abort = vi.fn();
    const pending = runLibraryAgentLoop(
      options({
        signal: controller.signal,
        runLeg: vi.fn(() => hangingLeg(abort)),
      }),
    );
    await Promise.resolve();
    controller.abort();

    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(abort).toHaveBeenCalledOnce();
  });

  it("aborts pending tool execution, rate-limit backoff, and confirmation", async () => {
    const toolController = new AbortController();
    const executeTool = vi.fn(
      (_tool, _args, _toolCallId, signal) =>
        new Promise<never>((_resolve, reject) => {
          signal.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true },
          );
        }),
    );
    const toolPending = runLibraryAgentLoop(
      options({
        signal: toolController.signal,
        runLeg: vi.fn(() =>
          streamLeg([
            callsEvent(call("list-1", "library_list", { source: "notion" })),
          ]),
        ),
        executeTool,
      }),
    );
    await vi.waitFor(() => expect(executeTool).toHaveBeenCalledOnce());
    toolController.abort();
    await expect(toolPending).rejects.toMatchObject({ name: "AbortError" });

    const backoffController = new AbortController();
    const onQuota = vi.fn();
    const rateLimitedTool = vi.fn(async () => {
      throw new LibraryAPIError("slow down", 429, "library_rate_limited", 5, {
        used: 20,
        limit: 20,
        remaining: 0,
      });
    });
    const backoffPending = runLibraryAgentLoop(
      options({
        signal: backoffController.signal,
        runLeg: vi.fn(() =>
          streamLeg([
            callsEvent(call("list-1", "library_list", { source: "notion" })),
          ]),
        ),
        executeTool: rateLimitedTool,
        onQuota,
      }),
    );
    await vi.waitFor(() => expect(rateLimitedTool).toHaveBeenCalledOnce());
    expect(onQuota).toHaveBeenCalledWith({ used: 20, limit: 20, remaining: 0 });
    backoffController.abort();
    await expect(backoffPending).rejects.toMatchObject({ name: "AbortError" });

    const confirmController = new AbortController();
    const requestConfirmation = vi.fn(
      (_request) =>
        new Promise<"cancel">((resolve) => {
          confirmController.signal.addEventListener(
            "abort",
            () => resolve("cancel"),
            { once: true },
          );
        }),
    );
    const confirmPending = runLibraryAgentLoop(
      options({
        signal: confirmController.signal,
        runLeg: vi.fn(() =>
          streamLeg([
            callsEvent(
              call("read-1", "library_read", {
                source: "notion",
                docId: "doc-1",
              }),
            ),
          ]),
        ),
        executeTool: vi.fn(async () => ({
          result: readResult({
            sensitive: { hit: true },
            redacted: {
              title: "Roadmap",
              sections: [{ text: "[REDACTED_SECRET]" }],
            },
          }),
        })),
        requestConfirmation,
      }),
    );
    await vi.waitFor(() => expect(requestConfirmation).toHaveBeenCalledOnce());
    confirmController.abort();
    await expect(confirmPending).rejects.toMatchObject({ name: "AbortError" });
  });

  // A first leg with zero tool calls used to be treated as "the model decided not to search" and
  // returned directly, when it is exactly the signal that most warrants a fallback: the model is
  // inventing an answer while the user believes a search happened.
  it("discards the first leg's text when it makes no tool call and a fallback is available, answering again from server evidence", async () => {
    const legs: LibraryAgentLegRequest[] = [];
    const texts: string[] = [];
    const onFirstLegWithoutToolCalls = vi.fn(async () => ({
      systemInstruction: "Untrusted evidence.",
      userContext: "<library_context>evidence</library_context>",
      citations: [
        {
          index: 1,
          url: "https://www.notion.so/doc-1",
          title: "Roadmap",
          docId: "doc-1",
          source: "notion" as const,
        },
      ],
      steps: [
        {
          id: "server:1:library_search",
          tool: "library_search" as const,
          label: "plan",
          status: "completed" as const,
          step: 1,
        },
      ],
    }));

    const result = await runLibraryAgentLoop(
      options({
        onFirstLegWithoutToolCalls,
        onText: (text) => texts.push(text),
        runLeg: (request) => {
          legs.push(request);
          return streamLeg([
            {
              type: "delta",
              content: legs.length === 1 ? "Made-up answer." : "Grounded answer.",
            },
          ]);
        },
      }),
    );

    expect(onFirstLegWithoutToolCalls).toHaveBeenCalledOnce();
    expect(result.text).toBe("Grounded answer.");
    // The invented first-leg text must not stay in the stream.
    expect(texts).toContain("");
    expect(texts.at(-1)).toBe("Grounded answer.");
    // The evidence is appended to the last user message, and the answering leg is given no tools.
    expect(legs[1]?.toolChoice).toBe("none");
    expect(legs[1]?.messages.at(-1)).toMatchObject({
      role: "user",
      content: expect.stringContaining("<library_context>evidence</library_context>"),
    });
    expect(legs[1]?.messages[0]).toMatchObject({
      role: "system",
      content: "Untrusted evidence.",
    });
    expect(result.citations).toHaveLength(1);
    expect(result.steps).toHaveLength(1);
  });

  it("keeps the first leg's text as the final answer when no fallback is available", async () => {
    const texts: string[] = [];
    const runLeg = vi.fn(() =>
      streamLeg([{ type: "delta", content: "No result." }]),
    );
    const result = await runLibraryAgentLoop(
      options({
        runLeg,
        onText: (text) => texts.push(text),
        onFirstLegWithoutToolCalls: vi.fn(async () => null),
      }),
    );

    expect(result.text).toBe("No result.");
    expect(runLeg).toHaveBeenCalledOnce();
    // It has to be put back after being cleared, otherwise the user sees an empty bubble.
    expect(texts.at(-1)).toBe("No result.");
  });

  it("only falls back on the first leg, since a later leg with no tool call is a normal ending", async () => {
    const onFirstLegWithoutToolCalls = vi.fn(async () => null);
    let leg = 0;
    await runLibraryAgentLoop(
      options({
        onFirstLegWithoutToolCalls,
        runLeg: () => {
          leg += 1;
          if (leg === 1) {
            return streamLeg([
              callsEvent(call("s1", "library_search", { query: "plan" })),
            ]);
          }
          return streamLeg([{ type: "delta", content: "Done." }]);
        },
        executeTool: vi.fn(async () => ({ result: { hits: [] } })),
      }),
    );

    expect(onFirstLegWithoutToolCalls).not.toHaveBeenCalled();
  });

  // A model may read three to five documents in one research round, and asking per document would
  // stack a queue of dialogs on the send path, while the user's answer about this batch of evidence
  // is obviously the same. The scope is one round.
  it("asks about sensitive content once per research round", async () => {
    const requestConfirmation = vi.fn(async () => "redact" as const);
    let leg = 0;
    const sensitive = (docId: string): LibraryReadResult => readResult({
      docId,
      sections: [{ text: `raw-${docId}` }],
      sensitive: { hit: true, kinds: ["credential"] },
      redacted: { title: docId, sections: [{ text: `[REDACTED_${docId}]` }] },
    });

    await runLibraryAgentLoop(options({
      runLeg: vi.fn(() => {
        leg += 1;
        return leg === 1
          ? streamLeg([callsEvent(
              call("call-1", "library_read", { docId: "a", source: "notion" }),
              call("call-2", "library_read", { docId: "b", source: "notion" }),
            )])
          : streamLeg([{ type: "delta", content: "done" }]);
      }),
      executeTool: vi.fn(async (_tool, args) => ({
        result: sensitive((args as { docId: string }).docId),
      })),
      requestConfirmation,
    }));

    expect(requestConfirmation).toHaveBeenCalledTimes(1);
  });
});
