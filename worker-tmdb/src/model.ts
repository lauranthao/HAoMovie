// Shared model types for the matcher.
// Architecture: yingxia tmdb-match src/model.ts (same shape, own code).

export class ModelError extends Error {}

export interface ToolCall {
  id?: string;
  name: string;
  args: Record<string, unknown>;
}

export interface ToolResult {
  call: ToolCall;
  result: unknown;
}
