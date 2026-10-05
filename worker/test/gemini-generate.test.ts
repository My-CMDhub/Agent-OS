// The /gemini-generate allow-list, run without a network:
//   cd worker && node_modules/.bin/esbuild test/gemini-generate.test.ts --bundle --platform=node --outfile=/tmp/gg.test.js && node /tmp/gg.test.js
import assert from "node:assert/strict";
import { buildGeminiGenerate, GEMINI_GENERATE_MODELS } from "../src/gemini";

const ok = buildGeminiGenerate(
  {
    model: GEMINI_GENERATE_MODELS[0],
    request: {
      contents: [{ role: "user", parts: [{ text: "hi" }] }],
      tools: [{ functionDeclarations: [] }, { googleSearch: {} }, { urlContext: {} }],
      generationConfig: { maxOutputTokens: 10 },
      cachedContent: "cachedContents/someone-elses",
      safetySettings: [{ category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE" }],
    },
    headers: { "x-goog-user-project": "elsewhere" },
  },
  "KEY"
);
assert.ok("url" in ok);
if ("url" in ok) {
  assert.equal(ok.url, `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_GENERATE_MODELS[0]}:generateContent`);
  // Exactly two headers, both the worker's own: nothing the client sent is forwarded.
  assert.deepEqual(Object.keys(ok.init.headers as Record<string, string>).sort(), ["content-type", "x-goog-api-key"]);
  const body = JSON.parse(ok.init.body as string);
  assert.deepEqual(Object.keys(body).sort(), ["contents", "generationConfig", "tools"]);
}
// A model off the list, a path in the model name, a tool off the list: refused.
assert.ok("error" in buildGeminiGenerate({ model: "gemini-ultra-expensive", request: { contents: [] } }, "KEY"));
assert.ok("error" in buildGeminiGenerate({ model: "../files", request: { contents: [] } }, "KEY"));
assert.ok("error" in buildGeminiGenerate({ model: GEMINI_GENERATE_MODELS[0], request: { contents: [], tools: [{ codeExecution: {} }] } }, "KEY"));
assert.ok("error" in buildGeminiGenerate({ model: GEMINI_GENERATE_MODELS[0], request: {} }, "KEY"));
console.log("gemini-generate: ok");
