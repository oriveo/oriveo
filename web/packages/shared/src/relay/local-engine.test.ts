import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { LOCAL_ENGINE_TEMPLATES, classifyLocalEngineResponse, localModelLocality, type LocalEngineKind } from './local-engine';

type Scenario = {
  id: string;
  engine: string;
  response: { status: number; headers: Record<string, string>; body?: unknown };
};

function fixture(): { scenarios: Scenario[] } {
  let directory = process.cwd();
  while (path.dirname(directory) !== directory) {
    const candidate = path.join(directory, 'shared/test-fixtures/local-engine/scenarios.v1.json');
    if (fs.existsSync(candidate)) return JSON.parse(fs.readFileSync(candidate, 'utf8'));
    directory = path.dirname(directory);
  }
  throw new Error('local engine fixture not found');
}

describe('local engine production response classifier', () => {
  it('classifies every non-stream fixture through production code', () => {
    const expected: Record<string, string> = {
      'llamacpp.ready': 'ready',
      'llamacpp.loading': 'loading',
      'llamacpp.props': 'wrong_engine',
      'ollama.ready': 'ready',
      'ollama.show': 'wrong_engine',
      'ollama.cloud_model': 'ready',
      'lmstudio.ready': 'ready',
      'lmstudio.loading': 'loading',
      'vllm.ready': 'ready',
      'openwebui.ready': 'ready',
      'openwebui.models_shape': 'ready',
      wrong_engine_on_expected_port: 'wrong_engine',
      parameter_rejected_400: 'parameter_rejected',
    };
    for (const scenario of fixture().scenarios.filter((item) => item.response.body !== undefined)) {
      const requestedEngine: LocalEngineKind = scenario.engine === 'not-llamacpp'
        ? 'llamacpp'
        : scenario.engine === 'generic-openai'
          ? 'vllm'
          : scenario.engine as LocalEngineKind;
      expect(classifyLocalEngineResponse(
        requestedEngine,
        scenario.response.status,
        scenario.response.headers['content-type'] ?? '',
        scenario.response.body,
      ), scenario.id).toBe(expected[scenario.id]);
    }
  });

  // Regression: classify identifies LM Studio by data[].state, which only /api/v0/models returns.
  // Falling back to the OpenAI-compatible /v1/models or /api/v1/models would classify a real
  // LM Studio as wrong_engine.
  it('keeps LM Studio metadata paths paired with the data[].state classify shape', () => {
    // Captured response from a real LM Studio /api/v0/models
    const v0Payload = JSON.parse('{"data":[{"id":"qwen/qwen3-0.6b","object":"model","type":"llm","state":"loaded"}],"object":"list"}');
    expect(classifyLocalEngineResponse('lmstudio', 200, 'application/json', v0Payload)).toBe('ready');

    // The same LM Studio on the OpenAI-compatible /v1/models: no state, and the shape is indistinguishable from vLLM, so wrong_engine must stand (anti-regression anchor)
    const openAIPayload = JSON.parse('{"data":[{"id":"qwen/qwen3-0.6b","object":"model","owned_by":"organization_owner"}],"object":"list"}');
    expect(classifyLocalEngineResponse('lmstudio', 200, 'application/json', openAIPayload)).toBe('wrong_engine');

    const template = LOCAL_ENGINE_TEMPLATES.lmstudio;
    expect(template.probe.path).toBe('/api/v0/models');
    expect(template.catalogPath).toBe('/api/v0/models');
    expect(template.introspection.path).toBe('/api/v0/models');
  });

  it('does not present an Ollama cloud model as local', () => {
    expect(localModelLocality('ollama', 'fixture:cloud')).toBe('cloud');
    expect(localModelLocality('ollama', 'fixture:latest')).toBe('local');
  });

  it('exposes all five release engine templates including bearer-only Open WebUI', () => {
    expect(Object.keys(LOCAL_ENGINE_TEMPLATES)).toEqual([
      'llamacpp', 'ollama', 'lmstudio', 'vllm', 'openwebui',
    ]);
    expect(LOCAL_ENGINE_TEMPLATES.openwebui).toMatchObject({
      defaultEndpoint: 'https://127.0.0.1:3000',
      catalogPath: '/api/models',
      generationPaths: ['/api/chat/completions'],
    });
  });
});
