// The Next.js server route never learns from rejected-parameter observations. This is the one cell in
// the permission matrix that must never learn, and it is locked down here.
//
// The reason is not that it is unfinished: `/api/chat/stream` is a process shared across users. A
// negative cache written here would apply one user's relay 400 to another user's request, possibly
// against a completely different upstream. Learning happens in the per-user processes instead: the
// browser and the desktop client.
//
// Everything asserted comes from production code: the scope is produced by the production
// `serverSelfHealScope` and parameter dropping and retrying is performed by the production
// `executeWithUnsupportedParamSelfHeal`. The test fabricates no events.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import {
  droppedUnsupportedParams,
  executeWithUnsupportedParamSelfHeal,
  markUnsupportedParamDropped,
  resetUnsupportedParamCacheForTesting,
  serverSelfHealScope,
} from "../unsupported-param";

const ROUTE_SOURCE = readFileSync(
  resolve(process.cwd(), "app/api/chat/stream/route.ts"),
  "utf8",
);

function buildReq(body: Record<string, unknown>) {
  return { url: "https://api.openai.com/v1/chat/completions", headers: {}, body };
}

beforeEach(() => resetUnsupportedParamCacheForTesting());

describe("the server route's self-heal scope never writes a negative cache", () => {
  it("markUnsupportedParamDropped is always ineligible and droppedUnsupportedParams is always empty", () => {
    const scope = serverSelfHealScope("openAI", "gpt-5.6", "openai_chat");

    expect(markUnsupportedParamDropped(scope, "temperature")).toBe("ineligible");
    expect(markUnsupportedParamDropped(scope, "temperature")).toBe("ineligible");
    expect(droppedUnsupportedParams(scope)).toEqual([]);
  });

  it("two requests on the same scope: the second still carries the rejected parameter unchanged, with no cross-request pre-dropping", async () => {
    const scope = serverSelfHealScope("openAI", "gpt-5.6", "openai_chat");
    const outbound: Array<Record<string, unknown>> = [];
    const execute = async (request: ReturnType<typeof buildReq>): Promise<Response> => {
      outbound.push(request.body);
      return outbound.length === 1
        ? new Response("does not support parameter temperature", { status: 400 })
        : new Response("{}", { status: 200 });
    };

    await executeWithUnsupportedParamSelfHeal(buildReq({ temperature: 0.5 }), { scope, execute });
    await executeWithUnsupportedParamSelfHeal(buildReq({ temperature: 0.5 }), { scope, execute });

    // This path does not scan the body or retry with the parameter dropped either, so the next request
    // keeps the original preference.
    expect(outbound.map((body) => body.temperature)).toEqual([0.5, 0.5]);
    expect(droppedUnsupportedParams(scope)).toEqual([]);
  });

  // route.ts does not call the self-heal path at all, which is stronger than using a scope that cannot
  // learn. The assertion is tightened to "the server route does not touch unsupported-parameter
  // self-healing and does not quietly fill in a connection identity". The two cases above still take
  // their evidence from the production `serverSelfHealScope` and `executeWithUnsupportedParamSelfHeal`.
  it("route.ts does not call unsupported-parameter self-healing and does not quietly fill in a connection identity", () => {
    expect(ROUTE_SOURCE).not.toContain("executeWithUnsupportedParamSelfHeal");
    expect(ROUTE_SOURCE).not.toContain("markUnsupportedParamDropped");
    expect(ROUTE_SOURCE).not.toContain("capabilityIdentity");
    expect(ROUTE_SOURCE).not.toContain("connectionInstanceId");
  });
});
