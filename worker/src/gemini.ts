// /gemini-generate's allow-lists, apart from index.ts so the worker module
// exports only its handler and the test can import this without a network.

// The agent loop's models, strongest first; the app falls back down this list.
export const GEMINI_GENERATE_MODELS = ["gemini-3.1-pro-preview", "gemini-3.8-flash", "gemini-2.5-pro"];
const GEMINI_GENERATE_FIELDS = ["contents", "systemInstruction", "tools", "toolConfig", "generationConfig"] as const;
// Function calling, and the two web tools; nothing that runs code or reaches files.
const GEMINI_GENERATE_TOOL_KINDS = new Set(["functionDeclarations", "googleSearch", "urlContext"]);

/**
 * The upstream request for /gemini-generate, rebuilt from allow-lists: the
 * model from GEMINI_GENERATE_MODELS, only GEMINI_GENERATE_FIELDS of the body,
 * only GEMINI_GENERATE_TOOL_KINDS of tools, and headers the worker writes
 * itself. Nothing else the client sends reaches Google. Exported for the test.
 */
export function buildGeminiGenerate(requested: unknown, apiKey: string): { url: string; init: RequestInit } | { error: string } {
  const asked = (requested ?? {}) as { model?: unknown; request?: Record<string, unknown> };
  if (typeof asked.model !== "string" || !GEMINI_GENERATE_MODELS.includes(asked.model)) {
    return { error: `model must be one of ${GEMINI_GENERATE_MODELS.join(", ")}` };
  }
  const request = asked.request ?? {};
  if (!Array.isArray(request.contents)) return { error: "request.contents must be an array" };
  const tools = request.tools ?? [];
  if (!Array.isArray(tools) || tools.some((tool) => typeof tool !== "object" || tool === null
      || Object.keys(tool).some((kind) => !GEMINI_GENERATE_TOOL_KINDS.has(kind)))) {
    return { error: `tools may hold only ${[...GEMINI_GENERATE_TOOL_KINDS].join(", ")}` };
  }
  const upstreamBody: Record<string, unknown> = {};
  for (const field of GEMINI_GENERATE_FIELDS) {
    if (request[field] !== undefined) upstreamBody[field] = request[field];
  }
  return {
    url: `https://generativelanguage.googleapis.com/v1beta/models/${asked.model}:generateContent`,
    init: {
      method: "POST",
      headers: { "x-goog-api-key": apiKey, "content-type": "application/json" },
      body: JSON.stringify(upstreamBody),
    },
  };
}
