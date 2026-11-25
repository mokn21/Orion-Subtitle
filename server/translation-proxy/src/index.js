const MODEL = "gemini-3.5-flash-lite";
const MAX_TEXT_LENGTH = 500;

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }
    if (request.method !== "POST") {
      return json({ error: "POST only" }, 405);
    }

    const client = request.headers.get("X-Orion-Client") || "";
    if (!client.startsWith("OrionSubtitles/")) {
      return json({ error: "Invalid client" }, 403);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "Invalid JSON" }, 400);
    }

    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text || text.length > MAX_TEXT_LENGTH) {
      return json({ error: "Text must contain 1-500 characters" }, 400);
    }
    if (body.sourceLanguage !== "en" || body.targetLanguage !== "ar") {
      return json({ error: "Only English to Arabic is enabled" }, 400);
    }
    if (!env.GEMINI_API_KEY) {
      return json({ error: "Translation service is not configured" }, 503);
    }

    const prompt = [
      "Translate the following English video-game subtitle into natural Modern Standard Arabic.",
      "Return only the Arabic translation. Do not add quotes, notes, explanations, transliteration, or the original English.",
      "Preserve names, numbers, buttons, and line breaks when useful.",
      "English subtitle:",
      text,
    ].join("\n");

    const upstream = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": env.GEMINI_API_KEY,
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 128,
          },
        }),
      },
    );

    if (!upstream.ok) {
      const detail = await upstream.text();
      console.error(`Gemini ${upstream.status}: ${detail.slice(0, 500)}`);
      return json({ error: "External AI request failed" }, 502);
    }

    const result = await upstream.json();
    const translation = result?.candidates?.[0]?.content?.parts
      ?.map((part) => part.text || "")
      .join("")
      .trim();
    if (!translation) {
      return json({ error: "External AI returned no translation" }, 502);
    }

    return json({ translation });
  },
};

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, X-Orion-Client",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}
