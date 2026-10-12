// The /openai-agent allow-list, run without a network:
//   cd worker && node_modules/.bin/esbuild test/openai-agent.test.ts --bundle --platform=node --outfile=/tmp/oa.test.js && node /tmp/oa.test.js
import assert from "node:assert/strict";
import { buildOpenAIAgent, OPENAI_AGENT_MODELS, OPENAI_AGENT_MAX_BODY_CHARACTERS } from "../src/openai";

const build = (body: unknown) => buildOpenAIAgent(JSON.stringify(body), "KEY");
const image = (url: string) => ({ role: "user", content: [{ type: "image_url", image_url: { url } }] });
const tool = { type: "function", function: { name: "scroll", parameters: { type: "object" } } };

const ok = build({
  model: OPENAI_AGENT_MODELS[0],
  request: {
    messages: [{ role: "system", content: "s" }, image("data:image/jpeg;base64,QUJD"), { role: "tool", tool_call_id: "c1", content: "{}" }],
    tools: [tool],
    tool_choice: "auto",
    max_completion_tokens: 4096,
    reasoning_effort: "low",
    store: true,
    metadata: { who: "else" },
    web_search_options: {},
  },
  headers: { "openai-organization": "elsewhere" },
});
assert.ok("url" in ok);
if ("url" in ok) {
  assert.equal(ok.url, "https://api.openai.com/v1/chat/completions");
  // Exactly two headers, both the worker's own: nothing the client sent is forwarded.
  assert.deepEqual(Object.keys(ok.init.headers as Record<string, string>).sort(), ["authorization", "content-type"]);
  const body = JSON.parse(ok.init.body as string);
  assert.deepEqual(Object.keys(body).sort(), ["max_completion_tokens", "messages", "model", "reasoning_effort", "tool_choice", "tools"]);
  assert.equal(body.model, OPENAI_AGENT_MODELS[0]);
}
assert.ok("url" in build({ model: "gpt-4.1-mini", request: { messages: [] } }));
// A model off the list, a non-function tool, an image OpenAI would fetch, a stray role, no messages, junk, too big: refused.
const refused = (result: ReturnType<typeof build>, status = 400) => assert.ok("error" in result && result.status === status, JSON.stringify(result));
refused(build({ model: "gpt-5", request: { messages: [] } }));
refused(build({ model: "o3-pro", request: { messages: [] } }));
refused(build({ model: OPENAI_AGENT_MODELS[0], request: { messages: [], tools: [tool, { type: "custom", custom: { name: "x" } }] } }));
refused(build({ model: OPENAI_AGENT_MODELS[0], request: { messages: [image("https://example.com/a.png")] } }));
refused(build({ model: OPENAI_AGENT_MODELS[0], request: { messages: [{ role: "function", content: "x" }] } }));
refused(build({ model: OPENAI_AGENT_MODELS[0], request: {} }));
refused(buildOpenAIAgent("{not json", "KEY"));
refused(buildOpenAIAgent(" ".repeat(OPENAI_AGENT_MAX_BODY_CHARACTERS + 1), "KEY"), 413);
console.log("openai-agent: ok");
