// Picks the model provider from env. The model name is a plain var, so the
// deployed model can change without touching code. No key is ever read from
// anywhere but the Worker's secrets (see README.md).
// Architecture: yingxia tmdb-match src/provider.ts (same shape, own code).
import type { Gemini } from "./agent.ts";
import { ModelError } from "./model.ts";
import type { OpenAI } from "./openai.ts";

interface Config {
  AI_PROVIDER?: string;
  OPENAI_API_KEY?: string;
  OPENAI_MODEL?: string;
  GEMINI_API_KEY?: string;
  GEMINI_MODEL?: string;
}

export function modelConfig(env: Config): OpenAI | (Gemini & { provider: "gemini" }) {
  const provider = env.AI_PROVIDER ?? "openai";
  if (provider === "openai") {
    if (!env.OPENAI_API_KEY?.trim()) throw new ModelError("OPENAI_API_KEY is not configured.");
    return { provider, key: env.OPENAI_API_KEY.trim(), model: env.OPENAI_MODEL || "gpt-4o-mini" };
  }
  if (provider === "gemini") {
    if (!env.GEMINI_API_KEY?.trim()) throw new ModelError("GEMINI_API_KEY is not configured.");
    return { provider, key: env.GEMINI_API_KEY.trim(), model: env.GEMINI_MODEL || "gemini-2.0-flash" };
  }
  throw new ModelError("AI_PROVIDER must be openai or gemini.");
}
