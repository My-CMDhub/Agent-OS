/**
 * Clicky Proxy Worker
 *
 * Proxies requests to paid speech and language APIs so the app never ships
 * with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Every route requires the header `X-Clicky-Client-Key` to equal the secret
 * `CLICKY_CLIENT_KEY`. Without that, this worker is an open proxy for every
 * key it holds — Clicky's upstream repo had exactly that reported
 * (farzaa/clicky issue #34). If the secret is unset, every request is refused.
 *
 * Routes (all POST):
 *   /chat               → Anthropic Messages API (streaming)
 *   /tts                → ElevenLabs TTS API                     (parked)
 *   /transcribe-token   → AssemblyAI streaming token             (parked)
 *   /deepgram-token     → Deepgram short-lived JWT (ttl 60 s) for Nova-3 streaming
 *   /openai-tts         → OpenAI /v1/audio/speech, gpt-4o-mini-tts only, streamed through
 *   /gemini-live-token  → Gemini Live API ephemeral token, one use, model locked
 *   /openai-realtime-token → OpenAI Realtime ephemeral client secret (60 s), gpt-realtime-mini locked
 *
 * Secrets:
 *   CLICKY_CLIENT_KEY, ANTHROPIC_API_KEY, ELEVENLABS_API_KEY, ASSEMBLYAI_API_KEY,
 *   DEEPGRAM_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY
 * Vars (wrangler.toml):
 *   ELEVENLABS_VOICE_ID
 */

interface Env {
  CLICKY_CLIENT_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
  DEEPGRAM_API_KEY?: string;
  OPENAI_API_KEY?: string;
  GEMINI_API_KEY?: string;
}

const OPENAI_TTS_ALLOWED_MODEL = "gpt-4o-mini-tts";
// OpenAI's own documented maximum for `input`; refusing here costs nothing upstream.
const OPENAI_TTS_MAX_INPUT_CHARACTERS = 4096;
const OPENAI_TTS_PASSTHROUGH_FIELDS = ["voice", "instructions", "response_format", "stream_format"] as const;

const GEMINI_LIVE_MODEL = "gemini-3.1-flash-live-preview";

const OPENAI_REALTIME_MODEL = "gpt-realtime-mini";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // The guard runs before routing and before the method check, so an
    // unauthenticated caller learns nothing about which routes exist.
    const refusal = await refuseUnlessClientKeyMatches(request, env);
    if (refusal) {
      return refusal;
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      switch (url.pathname) {
        case "/chat":
          return await handleChat(request, env);
        case "/tts":
          return await handleTTS(request, env);
        case "/transcribe-token":
          return await handleTranscribeToken(env);
        case "/deepgram-token":
          return await handleDeepgramToken(env);
        case "/openai-tts":
          return await handleOpenAITTS(request, env);
        case "/gemini-live-token":
          return await handleGeminiLiveToken(env);
        case "/openai-realtime-token":
          return await handleOpenAIRealtimeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

// MARK: - Client guard

async function refuseUnlessClientKeyMatches(request: Request, env: Env): Promise<Response | null> {
  if (!env.CLICKY_CLIENT_KEY) {
    // Fail closed: a forgotten secret must not quietly turn the guard off.
    return jsonResponse(
      { error: "CLICKY_CLIENT_KEY is unset on this worker, so every request is refused. Set it with `wrangler secret put CLICKY_CLIENT_KEY`." },
      503
    );
  }
  const presentedKey = request.headers.get("X-Clicky-Client-Key") ?? "";
  if (!(await constantTimeEquals(presentedKey, env.CLICKY_CLIENT_KEY))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  return null;
}

/**
 * Compares SHA-256 digests byte by byte without an early exit. Hashing first
 * makes both inputs 32 bytes, so neither the position of the first differing
 * byte nor the length of the real key shows up in the response time.
 */
async function constantTimeEquals(presented: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [presentedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const presentedBytes = new Uint8Array(presentedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let difference = 0;
  for (let index = 0; index < expectedBytes.length; index++) {
    difference |= presentedBytes[index] ^ expectedBytes[index];
  }
  return difference === 0;
}

// MARK: - Helpers

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Names the missing secret instead of sending the string "undefined" upstream. */
function missingSecretResponse(secretName: string): Response {
  return jsonResponse({ error: `${secretName} is unset on this worker.` }, 500);
}

async function upstreamErrorResponse(routeName: string, response: Response): Promise<Response> {
  const errorBody = await response.text();
  console.error(`[${routeName}] upstream error ${response.status}: ${errorBody}`);
  return new Response(errorBody, {
    status: response.status,
    headers: { "content-type": response.headers.get("content-type") || "application/json" },
  });
}

// MARK: - Anthropic

async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!env.ANTHROPIC_API_KEY) return missingSecretResponse("ANTHROPIC_API_KEY");
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    return upstreamErrorResponse("/chat", response);
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

// MARK: - Deepgram

async function handleDeepgramToken(env: Env): Promise<Response> {
  if (!env.DEEPGRAM_API_KEY) return missingSecretResponse("DEEPGRAM_API_KEY");

  // https://developers.deepgram.com/reference/auth/tokens/grant
  // The grant endpoint takes the long-lived key as `Token`; the JWT it returns
  // is then presented to /v1/listen as `Bearer`.
  const response = await fetch("https://api.deepgram.com/v1/auth/grant", {
    method: "POST",
    headers: {
      authorization: `Token ${env.DEEPGRAM_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ ttl_seconds: 60 }),
  });

  if (!response.ok) {
    return upstreamErrorResponse("/deepgram-token", response);
  }
  // { access_token, expires_in }
  return new Response(await response.text(), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// MARK: - OpenAI

async function handleOpenAITTS(request: Request, env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) return missingSecretResponse("OPENAI_API_KEY");

  let requestedBody: Record<string, unknown>;
  try {
    requestedBody = await request.json();
  } catch {
    return jsonResponse({ error: "body must be JSON" }, 400);
  }

  // Only one model is allowed through: this route exists for one measured
  // comparison, not as a general OpenAI proxy.
  if (requestedBody.model !== OPENAI_TTS_ALLOWED_MODEL) {
    return jsonResponse({ error: `model must be ${OPENAI_TTS_ALLOWED_MODEL}` }, 400);
  }
  const input = requestedBody.input;
  if (typeof input !== "string" || input.length === 0 || input.length > OPENAI_TTS_MAX_INPUT_CHARACTERS) {
    return jsonResponse({ error: `input must be a non-empty string of at most ${OPENAI_TTS_MAX_INPUT_CHARACTERS} characters` }, 400);
  }

  // Rebuilt from an allow-list rather than forwarded, so nothing the client
  // adds reaches OpenAI unexamined.
  const upstreamBody: Record<string, unknown> = { model: OPENAI_TTS_ALLOWED_MODEL, input };
  for (const fieldName of OPENAI_TTS_PASSTHROUGH_FIELDS) {
    if (requestedBody[fieldName] !== undefined) {
      upstreamBody[fieldName] = requestedBody[fieldName];
    }
  }

  const response = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(upstreamBody),
  });

  if (!response.ok) {
    return upstreamErrorResponse("/openai-tts", response);
  }

  // The upstream body is handed straight back as a stream. Buffering it here
  // would turn time-to-first-byte into time-to-last-byte — the number this
  // route exists to measure.
  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "application/octet-stream",
      "cache-control": "no-cache",
    },
  });
}

// MARK: - Gemini

async function handleGeminiLiveToken(env: Env): Promise<Response> {
  if (!env.GEMINI_API_KEY) return missingSecretResponse("GEMINI_API_KEY");

  const now = Date.now();
  // https://ai.google.dev/gemini-api/docs/ephemeral-tokens and
  // https://ai.google.dev/api/live#ephemeral-auth-tokens
  // `bidiGenerateContentSetup` + `fieldMask` is the wire form the official SDKs
  // send for `liveConnectConstraints`. The field mask matters: with an EMPTY
  // mask the server takes the whole setup from the token and ignores the
  // client's setup (system instruction, activity detection) entirely. A mask of
  // "model" locks only the model and leaves the rest to the connection.
  const tokenRequest = {
    uses: 1,
    expireTime: new Date(now + 10 * 60 * 1000).toISOString(),
    newSessionExpireTime: new Date(now + 60 * 1000).toISOString(),
    bidiGenerateContentSetup: { model: `models/${GEMINI_LIVE_MODEL}` },
    fieldMask: "model",
  };

  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/auth_tokens", {
    method: "POST",
    headers: {
      "x-goog-api-key": env.GEMINI_API_KEY,
      "content-type": "application/json",
    },
    body: JSON.stringify(tokenRequest),
  });

  if (!response.ok) {
    return upstreamErrorResponse("/gemini-live-token", response);
  }

  const createdToken = (await response.json()) as { name?: string };
  if (!createdToken.name) {
    return jsonResponse({ error: "Gemini returned no token name" }, 502);
  }
  // The token only; nothing else from the upstream response leaves the worker.
  return jsonResponse({ token: createdToken.name }, 200);
}

async function handleOpenAIRealtimeToken(env: Env): Promise<Response> {
  if (!env.OPENAI_API_KEY) return missingSecretResponse("OPENAI_API_KEY");

  // https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create
  // The model is fixed here, not taken from the request body: the client gets a
  // secret for this one model and nothing it sends can buy a pricier one. The
  // rest of the session (instructions, formats, turn detection) is left to the
  // client's own session.update, as the Gemini route leaves it to the setup.
  // 60 s is enough to open the socket; an open session outlives its secret.
  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds: 60 },
      session: { type: "realtime", model: OPENAI_REALTIME_MODEL },
    }),
  });

  if (!response.ok) {
    return upstreamErrorResponse("/openai-realtime-token", response);
  }

  const createdSecret = (await response.json()) as { value?: string };
  if (!createdSecret.value) {
    return jsonResponse({ error: "OpenAI returned no client secret" }, 502);
  }
  // The secret only; the echoed session config stays in the worker.
  return jsonResponse({ token: createdSecret.value }, 200);
}

// MARK: - Parked routes (legacy Clicky voice path)

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) return missingSecretResponse("ASSEMBLYAI_API_KEY");
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    return upstreamErrorResponse("/transcribe-token", response);
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY) return missingSecretResponse("ELEVENLABS_API_KEY");
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    return upstreamErrorResponse("/tts", response);
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
