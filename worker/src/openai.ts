// /openai-agent's allow-lists, apart from index.ts like gemini.ts, so the test
// can import this without a network. The agent loop's FALLBACK (owner
// 2026-10-13): Gemini stays the default; OpenAI takes a step Gemini could not
// answer (429/5xx/timeout), and whole runs for settled comparisons.

// Must match AgentLoopOpenAI.models.
export const OPENAI_AGENT_MODELS = ["gpt-5-mini", "gpt-4.1-mini"];
const OPENAI_AGENT_FIELDS = ["messages", "tools", "tool_choice", "max_completion_tokens", "reasoning_effort"] as const;
const OPENAI_AGENT_ROLES = new Set(["system", "developer", "user", "assistant", "tool"]);
// One step is the history with one screenshot; ~1 MB measured scale, 8 MB leaves room and stops abuse.
export const OPENAI_AGENT_MAX_BODY_CHARACTERS = 8_000_000;

/**
 * The upstream request for /openai-agent, rebuilt from allow-lists: the model
 * from OPENAI_AGENT_MODELS, only OPENAI_AGENT_FIELDS of the body, function
 * tools only, images only as inline data (never a URL OpenAI would fetch), and
 * headers the worker writes itself. Exported for the test.
 */
export function buildOpenAIAgent(text: string, apiKey: string): { url: string; init: RequestInit } | { error: string; status: number } {
  if (text.length > OPENAI_AGENT_MAX_BODY_CHARACTERS) return { error: "body too large", status: 413 };
  let asked: { model?: unknown; request?: Record<string, unknown> };
  try {
    asked = JSON.parse(text) ?? {};
  } catch {
    return { error: "body must be JSON", status: 400 };
  }
  if (typeof asked.model !== "string" || !OPENAI_AGENT_MODELS.includes(asked.model)) {
    return { error: `model must be one of ${OPENAI_AGENT_MODELS.join(", ")}`, status: 400 };
  }
  const request = asked.request ?? {};
  const messages = request.messages;
  if (!Array.isArray(messages) || messages.some((message) => typeof message !== "object" || message === null
      || !OPENAI_AGENT_ROLES.has((message as { role?: string }).role ?? ""))) {
    return { error: "request.messages must be an array of system, developer, user, assistant or tool messages", status: 400 };
  }
  for (const message of messages as { content?: unknown }[]) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as { type?: string; image_url?: { url?: unknown } }[]) {
      if (part?.type === "image_url" && !(typeof part.image_url?.url === "string" && part.image_url.url.startsWith("data:image/"))) {
        return { error: "images must be inline data:image/ URLs", status: 400 };
      }
    }
  }
  const tools = request.tools ?? [];
  if (!Array.isArray(tools) || tools.some((tool) => (tool as { type?: string })?.type !== "function")) {
    return { error: "tools may hold only function tools", status: 400 };
  }
  const upstreamBody: Record<string, unknown> = { model: asked.model };
  for (const field of OPENAI_AGENT_FIELDS) {
    if (request[field] !== undefined) upstreamBody[field] = request[field];
  }
  return {
    url: "https://api.openai.com/v1/chat/completions",
    init: {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify(upstreamBody),
    },
  };
}
