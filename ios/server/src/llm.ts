// Minimal OpenAI-compatible client for DeepSeek: streaming chat with tool calls,
// plus a one-shot JSON helper for structured generations (briefs, insights).

export type ChatMessage =
  | { role: 'system' | 'user'; content: string }
  | { role: 'assistant'; content: string | null; tool_calls?: ToolCall[] }
  | { role: 'tool'; tool_call_id: string; content: string }

export interface ToolCall {
  id: string
  type: 'function'
  function: { name: string; arguments: string }
}

export interface ToolSpec {
  type: 'function'
  function: { name: string; description: string; parameters: Record<string, unknown> }
}

export interface LlmEnv {
  DEEPSEEK_API_KEY: string
  LLM_BASE_URL: string
  LLM_MODEL: string
}

export interface StreamResult {
  content: string
  toolCalls: ToolCall[]
}

async function post(env: LlmEnv, body: Record<string, unknown>): Promise<Response> {
  const res = await fetch(`${env.LLM_BASE_URL}/chat/completions`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.DEEPSEEK_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ model: env.LLM_MODEL, thinking: { type: 'disabled' }, ...body }),
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`LLM ${res.status}: ${text.slice(0, 300)}`)
  }
  return res
}

/** Streams one assistant turn. `onText` receives content deltas as they arrive. */
export async function streamChat(
  env: LlmEnv,
  messages: ChatMessage[],
  tools: ToolSpec[],
  onText: (delta: string) => void,
): Promise<StreamResult> {
  const res = await post(env, { messages, tools, stream: true, temperature: 0.8 })
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader()
  let buffer = ''
  let content = ''
  const calls: ToolCall[] = []

  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += value
    let nl: number
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim()
      buffer = buffer.slice(nl + 1)
      if (!line.startsWith('data:')) continue
      const data = line.slice(5).trim()
      if (data === '[DONE]') continue
      let chunk: any
      try {
        chunk = JSON.parse(data)
      } catch {
        continue
      }
      const delta = chunk.choices?.[0]?.delta
      if (!delta) continue
      if (typeof delta.content === 'string' && delta.content) {
        content += delta.content
        onText(delta.content)
      }
      for (const tc of delta.tool_calls ?? []) {
        const i = tc.index ?? 0
        calls[i] ??= { id: '', type: 'function', function: { name: '', arguments: '' } }
        if (tc.id) calls[i].id = tc.id
        if (tc.function?.name) calls[i].function.name += tc.function.name
        if (tc.function?.arguments) calls[i].function.arguments += tc.function.arguments
      }
    }
  }
  return { content, toolCalls: calls.filter(Boolean) }
}

/** One-shot completion that must return a JSON object. */
export async function completeJson<T>(env: LlmEnv, messages: ChatMessage[]): Promise<T> {
  const res = await post(env, {
    messages,
    response_format: { type: 'json_object' },
    temperature: 0.7,
  })
  const json: any = await res.json()
  const text: string = json.choices?.[0]?.message?.content ?? '{}'
  return JSON.parse(text) as T
}
