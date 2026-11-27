import { DurableObject } from 'cloudflare:workers'
import type { AuthEnv } from './auth'
import { completeJson, streamChat, type ChatMessage, type LlmEnv, type ToolSpec } from './llm'
import { CHARACTER, moodOf, stageForMood, systemPrompt, type StageState } from './persona'
import { SOURCE_IDS, geocode, summarize, weather, type LocationSnapshot, type SourceId } from './sources'

export interface Env extends LlmEnv, AuthEnv {
  COMPANION: DurableObjectNamespace<Companion>
}

const SEGMENT_GAP_MS = 4 * 60 * 60 * 1000
const MAX_CONTEXT_MESSAGES = 40
const MAX_TOOL_ROUNDS = 5

const SOURCE_LABELS: Record<SourceId, string> = {
  health: 'Health',
  calendar: 'Calendar & Reminders',
  location: 'Location',
}

type MessageRow = {
  id: number
  role: 'user' | 'assistant'
  content: string
  mood: string | null
  kind: string
  segment: number
  created_at: number
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })

const rid = () => crypto.randomUUID().slice(0, 8)

const TOOLS: ToolSpec[] = [
  {
    type: 'function',
    function: {
      name: 'remember',
      description: 'Save a durable note about the user (preference, person, plan, habit). One fact per call.',
      parameters: {
        type: 'object',
        properties: { note: { type: 'string', description: 'Third person, e.g. "Prefers oat milk"' } },
        required: ['note'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'forget',
      description: 'Delete a memory that is wrong or outdated, by its id.',
      parameters: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_create',
      description: 'Create a list the user can come back to, optionally with initial items.',
      parameters: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          items: { type: 'array', items: { type: 'string' } },
        },
        required: ['title'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_add',
      description: 'Add items to an existing list.',
      parameters: {
        type: 'object',
        properties: { list_id: { type: 'string' }, items: { type: 'array', items: { type: 'string' } } },
        required: ['list_id', 'items'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_update',
      description: 'Mark list items done or remove them. Items are matched by text (case-insensitive substring).',
      parameters: {
        type: 'object',
        properties: {
          list_id: { type: 'string' },
          done: { type: 'array', items: { type: 'string' } },
          remove: { type: 'array', items: { type: 'string' } },
        },
        required: ['list_id'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_read',
      description: 'Read the items of a list.',
      parameters: { type: 'object', properties: { list_id: { type: 'string' } }, required: ['list_id'] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_weather',
      description: "Weather now and the next 4 days. Omit place for the user's current location.",
      parameters: { type: 'object', properties: { place: { type: 'string' } } },
    },
  },
]

/** Which stage animation a tool call shows while it runs. */
const TOOL_STAGE: Record<string, StageState> = {
  remember: 'writing',
  forget: 'writing',
  list_create: 'writing',
  list_add: 'writing',
  list_update: 'writing',
  list_read: 'reading',
  get_weather: 'searching',
}

export class Companion extends DurableObject<Env> {
  private sql: SqlStorage

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.migrate()
  }

  private migrate() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS profile (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL, content TEXT NOT NULL, mood TEXT,
        kind TEXT NOT NULL DEFAULT 'chat', segment INTEGER NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS segments (id INTEGER PRIMARY KEY, started_at INTEGER NOT NULL, summary TEXT);
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY, text TEXT NOT NULL, origin TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS lists (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS list_items (
        id TEXT PRIMARY KEY, list_id TEXT NOT NULL, text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS sources (
        id TEXT PRIMARY KEY, snapshot TEXT NOT NULL, summary TEXT NOT NULL,
        shared INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS briefs (day TEXT PRIMARY KEY, body TEXT NOT NULL, created_at INTEGER NOT NULL);
    `)
  }

  // ---------- small storage helpers ----------

  private getProfile(): Record<string, string> {
    const out: Record<string, string> = {}
    for (const r of this.sql.exec<{ key: string; value: string }>('SELECT key, value FROM profile')) out[r.key] = r.value
    return out
  }
  private setProfile(key: string, value: string | undefined | null) {
    if (value == null || value === '') this.sql.exec('DELETE FROM profile WHERE key = ?', key)
    else this.sql.exec('INSERT INTO profile (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', key, value)
  }

  private memories() {
    return [...this.sql.exec<{ id: string; text: string; origin: string; created_at: number }>(
      'SELECT id, text, origin, created_at FROM memories ORDER BY created_at',
    )].map(r => ({ id: r.id, text: r.text, origin: r.origin, createdAt: r.created_at }))
  }
  private addMemory(text: string, origin: string) {
    const id = rid()
    this.sql.exec('INSERT INTO memories (id, text, origin, created_at) VALUES (?, ?, ?, ?)', id, text.trim(), origin, Date.now())
    return { id, text: text.trim(), origin, createdAt: Date.now() }
  }

  private lists() {
    const lists = [...this.sql.exec<{ id: string; title: string; created_at: number }>('SELECT * FROM lists ORDER BY created_at DESC')]
    return lists.map(l => ({
      id: l.id,
      title: l.title,
      createdAt: l.created_at,
      items: [...this.sql.exec<{ id: string; text: string; done: number; created_at: number }>(
        'SELECT id, text, done, created_at FROM list_items WHERE list_id = ? ORDER BY created_at', l.id,
      )].map(i => ({ id: i.id, text: i.text, done: !!i.done })),
    }))
  }

  private sources() {
    return [...this.sql.exec<{ id: string; summary: string; shared: number; updated_at: number }>(
      'SELECT id, summary, shared, updated_at FROM sources',
    )].map(s => ({ id: s.id, label: SOURCE_LABELS[s.id as SourceId] ?? s.id, summary: s.summary, shared: !!s.shared, updatedAt: s.updated_at }))
  }
  private location(): LocationSnapshot | null {
    const row = [...this.sql.exec<{ snapshot: string; shared: number }>("SELECT snapshot, shared FROM sources WHERE id = 'location'")][0]
    if (!row || !row.shared) return null
    return JSON.parse(row.snapshot)
  }

  private timezone(): string {
    return this.getProfile().timezone || 'Asia/Shanghai'
  }
  private nowLocal(): string {
    const tz = this.timezone()
    const f = new Intl.DateTimeFormat('en-CA', {
      timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'long', hour: '2-digit', minute: '2-digit', hour12: false,
    })
    return `${f.format(new Date())} (${tz})`
  }
  private language(): string {
    return this.getProfile().locale?.toLowerCase().startsWith('zh') ? 'Chinese' : 'English'
  }
  private localDay(): string {
    return new Intl.DateTimeFormat('en-CA', { timeZone: this.timezone() }).format(new Date())
  }

  // ---------- segments ----------

  private lastMessage(): MessageRow | undefined {
    return [...this.sql.exec<MessageRow>('SELECT * FROM messages ORDER BY id DESC LIMIT 1')][0]
  }

  /** Returns the segment a new message belongs to, opening a new one after a long gap. */
  private currentSegment(now: number): { segment: number; opened: boolean } {
    const last = this.lastMessage()
    if (last && now - last.created_at < SEGMENT_GAP_MS) return { segment: last.segment, opened: false }
    const segment = (last?.segment ?? 0) + 1
    this.sql.exec('INSERT OR IGNORE INTO segments (id, started_at) VALUES (?, ?)', segment, now)
    if (last) this.ctx.waitUntil(this.summarizeSegment(last.segment))
    return { segment, opened: true }
  }

  private async summarizeSegment(segment: number) {
    const rows = [...this.sql.exec<MessageRow>('SELECT * FROM messages WHERE segment = ? ORDER BY id', segment)]
    if (rows.length < 2) return
    const transcript = rows.map(r => `${r.role === 'user' ? 'User' : CHARACTER.name}: ${r.content}`).join('\n').slice(-12000)
    try {
      const out = await completeJson<{ summary: string }>(this.env, [
        {
          role: 'system',
          content: 'Summarize this conversation in 2-4 sentences for the assistant\'s own future reference: what was discussed, decisions, open threads. Write in the conversation\'s language. Return {"summary": string}.',
        },
        { role: 'user', content: transcript },
      ])
      this.sql.exec('UPDATE segments SET summary = ? WHERE id = ?', out.summary, segment)
    } catch (e) {
      console.error('summarize failed', e)
    }
  }

  private contextMessages(): { history: ChatMessage[]; summary?: string } {
    const last = this.lastMessage()
    if (!last) return { history: [] }
    const rows = [...this.sql.exec<MessageRow>(
      'SELECT * FROM messages WHERE segment >= ? ORDER BY id DESC LIMIT ?', last.segment - 1, MAX_CONTEXT_MESSAGES,
    )].reverse()
    const summaries = [...this.sql.exec<{ summary: string | null }>(
      'SELECT summary FROM segments WHERE id < ? AND summary IS NOT NULL ORDER BY id DESC LIMIT 3', last.segment,
    )].map(r => r.summary!).reverse()
    return {
      history: rows.map(r => ({ role: r.role, content: r.content }) as ChatMessage),
      summary: summaries.join('\n') || undefined,
    }
  }

  private buildSystem(summary?: string): string {
    const p = this.getProfile()
    return systemPrompt({
      userName: p.userName,
      nowLocal: this.nowLocal(),
      memories: this.memories(),
      sources: this.sources().filter(s => s.shared),
      lists: this.lists().map(l => ({ id: l.id, title: l.title, open: l.items.filter(i => !i.done).length })),
      segmentSummary: summary,
      language: this.language(),
    })
  }

  // ---------- tools ----------

  private async runTool(name: string, args: any, emit: (e: object) => void): Promise<string> {
    switch (name) {
      case 'remember': {
        const m = this.addMemory(String(args.note ?? ''), 'chat')
        emit({ type: 'memory', memory: m })
        return `saved [${m.id}]`
      }
      case 'forget': {
        this.sql.exec('DELETE FROM memories WHERE id = ?', String(args.id))
        emit({ type: 'memory_removed', id: String(args.id) })
        return 'deleted'
      }
      case 'list_create': {
        const id = rid()
        this.sql.exec('INSERT INTO lists (id, title, created_at) VALUES (?, ?, ?)', id, String(args.title), Date.now())
        for (const t of (args.items ?? []) as string[]) {
          this.sql.exec('INSERT INTO list_items (id, list_id, text, created_at) VALUES (?, ?, ?, ?)', rid(), id, t, Date.now())
        }
        emit({ type: 'list', listId: id })
        return `created list [${id}]`
      }
      case 'list_add': {
        const id = String(args.list_id)
        if (![...this.sql.exec('SELECT 1 FROM lists WHERE id = ?', id)].length) return 'no such list'
        for (const t of (args.items ?? []) as string[]) {
          this.sql.exec('INSERT INTO list_items (id, list_id, text, created_at) VALUES (?, ?, ?, ?)', rid(), id, t, Date.now())
        }
        emit({ type: 'list', listId: id })
        return 'added'
      }
      case 'list_update': {
        const id = String(args.list_id)
        const items = [...this.sql.exec<{ id: string; text: string }>('SELECT id, text FROM list_items WHERE list_id = ?', id)]
        const match = (q: string) => items.filter(i => i.text.toLowerCase().includes(q.toLowerCase()))
        for (const q of (args.done ?? []) as string[]) for (const i of match(q)) this.sql.exec('UPDATE list_items SET done = 1 WHERE id = ?', i.id)
        for (const q of (args.remove ?? []) as string[]) for (const i of match(q)) this.sql.exec('DELETE FROM list_items WHERE id = ?', i.id)
        emit({ type: 'list', listId: id })
        return 'updated'
      }
      case 'list_read': {
        const l = this.lists().find(l => l.id === String(args.list_id))
        if (!l) return 'no such list'
        return `${l.title}\n` + l.items.map(i => `- [${i.done ? 'x' : ' '}] ${i.text}`).join('\n')
      }
      case 'get_weather': {
        let target: { lat: number; lon: number; place: string } | null = null
        if (args.place) target = await geocode(String(args.place))
        else {
          const loc = this.location()
          if (loc) target = { lat: loc.lat, lon: loc.lon, place: loc.place ?? 'your location' }
        }
        if (!target) return args.place ? 'place not found' : 'location not shared; ask which city'
        return (await weather(target.lat, target.lon, target.place)).text
      }
    }
    return `unknown tool ${name}`
  }

  // ---------- chat ----------

  private chat(text: string): Response {
    const { readable, writable } = new TransformStream<Uint8Array>()
    const writer = writable.getWriter()
    const enc = new TextEncoder()
    const emit = (e: object) => writer.write(enc.encode(`data: ${JSON.stringify(e)}\n\n`)).catch(() => {})

    const work = async () => {
      const now = Date.now()
      const { history, summary } = this.contextMessages()
      const { segment } = this.currentSegment(now)
      this.sql.exec(
        "INSERT INTO messages (role, content, kind, segment, created_at) VALUES ('user', ?, 'chat', ?, ?)", text, segment, now,
      )
      const userId = [...this.sql.exec<{ id: number }>('SELECT last_insert_rowid() AS id')][0].id
      emit({ type: 'ack', userMessageId: userId })
      emit({ type: 'stage', state: 'reading' })

      const messages: ChatMessage[] = [
        { role: 'system', content: this.buildSystem(summary) },
        ...history,
        { role: 'user', content: text },
      ]
      let reply = ''
      let moodSent = false
      try {
        for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
          let roundText = ''
          const res = await streamChat(this.env, messages, round < MAX_TOOL_ROUNDS ? TOOLS : [], delta => {
            roundText += delta
            emit({ type: 'text', delta })
            if (!moodSent && /[）)]/.test(roundText)) {
              moodSent = true
              const mood = moodOf(roundText)
              emit({ type: 'stage', state: stageForMood(mood), mood })
            }
          })
          reply += res.content
          if (!res.toolCalls.length) break
          messages.push({ role: 'assistant', content: res.content || null, tool_calls: res.toolCalls })
          for (const call of res.toolCalls) {
            emit({ type: 'stage', state: TOOL_STAGE[call.function.name] ?? 'running' })
            emit({ type: 'tool', name: call.function.name })
            let result: string
            try {
              result = await this.runTool(call.function.name, JSON.parse(call.function.arguments || '{}'), emit)
            } catch (e) {
              result = `error: ${(e as Error).message}`
            }
            messages.push({ role: 'tool', tool_call_id: call.id, content: result })
          }
        }
        const mood = moodOf(reply)
        const at = Date.now()
        this.sql.exec(
          "INSERT INTO messages (role, content, mood, kind, segment, created_at) VALUES ('assistant', ?, ?, 'chat', ?, ?)",
          reply, mood, segment, at,
        )
        const id = [...this.sql.exec<{ id: number }>('SELECT last_insert_rowid() AS id')][0].id
        emit({ type: 'done', message: { id, role: 'assistant', content: reply, mood, kind: 'chat', segment, createdAt: at } })
      } catch (e) {
        console.error('chat failed', e)
        emit({ type: 'stage', state: 'failed' })
        emit({ type: 'error', message: (e as Error).message })
      } finally {
        await writer.close().catch(() => {})
      }
    }
    this.ctx.waitUntil(work())
    return new Response(readable, {
      headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no' },
    })
  }

  // ---------- today brief & onboarding insights ----------

  private async today(refresh: boolean) {
    const day = this.localDay()
    const newestSource = Math.max(0, ...this.sources().map(s => s.updatedAt))
    const cached = [...this.sql.exec<{ body: string; created_at: number }>('SELECT body, created_at FROM briefs WHERE day = ?', day)][0]
    if (cached && !refresh && cached.created_at >= newestSource) return JSON.parse(cached.body)

    const loc = this.location()
    const wx = loc ? await weather(loc.lat, loc.lon, loc.place ?? 'here').catch(() => null) : null
    const p = this.getProfile()
    const sources = this.sources().filter(s => s.shared)
    const out = await completeJson<{
      greeting: string
      items: { kind: string; text: string }[]
      suggestions: { kind: string; title: string; detail: string; prompt: string }[]
    }>(this.env, [
      {
        role: 'system',
        content: `${this.buildSystem()}

## Task
Write the "today" card the user sees when they come back after a while. Return JSON:
{"greeting": string, "items": [{"kind": "weather"|"calendar"|"health"|"reminder"|"note", "text": string}], "suggestions": [{"kind": "weather"|"calendar"|"health"|"list"|"food"|"fun", "title": string, "detail": string, "prompt": string}]}
- greeting: in character, opening stage direction then one or two sentences that fit the time of day and something real about their day. Language: ${this.language()} for every field, including the stage direction.
- items: 2-4 short facts worth knowing today, each under 40 characters, drawn only from the data below. Skip kinds you have no data for.
- suggestions: 3 cards for things you could help with next, varied: one practical, one about their day, one playful. "title" is 2-4 words naming the help (e.g. "Plan lunch", "Sleep check"); "detail" is one sentence (under 60 characters) on what you'd do, tied to their day; "prompt" is what the user would send to ask for it, first person.`,
      },
      { role: 'user', content: `Weather:\n${wx?.text ?? 'unknown'}\n\nShared sources: ${sources.map(s => s.label).join(', ') || 'none'}` },
    ])
    const body = { day, ...out, weather: wx?.now ? { ...wx.now, place: wx.place } : null }
    this.sql.exec(
      'INSERT INTO briefs (day, body, created_at) VALUES (?, ?, ?) ON CONFLICT(day) DO UPDATE SET body = excluded.body, created_at = excluded.created_at',
      day, JSON.stringify(body), Date.now(),
    )
    return body
  }

  private async insights() {
    const sources = this.sources().filter(s => s.shared)
    const p = this.getProfile()
    if (!sources.length) return { intro: null, insights: [] }
    return completeJson<{ intro: string; insights: { text: string; memory: string }[] }>(this.env, [
      {
        role: 'system',
        content: `${this.buildSystem()}

## Task
${p.userName ?? 'The user'} just let you see their data for the first time. Show them you already understand a little about their life. Return JSON:
{"intro": string, "insights": [{"text": string, "memory": string}]}
- intro: in character, opening stage direction, one sentence before the cards (e.g. you looked through their week).
- insights: exactly 3. "text" is what you say to them, warm and specific, one sentence, citing a concrete number or time from the data. "memory" is the durable pattern behind it in third person ("Usually goes to bed around 01:20"); use "" when the insight is about a one-off item (a single event or reminder), since those are not worth remembering. Only use facts present in the data. Prefer patterns over one-off events.
Language: ${this.language()} (the stage direction too).`,
      },
      { role: 'user', content: 'Look at what I shared and tell me what you notice.' },
    ])
  }

  // ---------- HTTP ----------

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url)
    const path = url.pathname.replace(/^\/v1/, '')
    const tz = req.headers.get('X-Timezone')
    if (tz && tz !== this.getProfile().timezone) this.setProfile('timezone', tz)
    const locale = req.headers.get('X-Locale')
    if (locale && locale !== this.getProfile().locale) this.setProfile('locale', locale)

    try {
      if (req.method === 'GET' && path === '/state') {
        return json({
          profile: this.getProfile(),
          character: { name: CHARACTER.name, greeting: CHARACTER.greeting },
          memories: this.memories(),
          lists: this.lists(),
          sources: this.sources(),
        })
      }
      if (req.method === 'PUT' && path === '/profile') {
        const body: Record<string, string | null> = await req.json()
        for (const k of ['userName', 'onboardedAt']) if (k in body) this.setProfile(k, body[k])
        return json({ profile: this.getProfile() })
      }
      if (req.method === 'GET' && path === '/messages') {
        const before = Number(url.searchParams.get('before') ?? Number.MAX_SAFE_INTEGER)
        const limit = Math.min(Number(url.searchParams.get('limit') ?? 60), 200)
        const rows = [...this.sql.exec<MessageRow>('SELECT * FROM messages WHERE id < ? ORDER BY id DESC LIMIT ?', before, limit)].reverse()
        return json({
          messages: rows.map(r => ({ id: r.id, role: r.role, content: r.content, mood: r.mood, kind: r.kind, segment: r.segment, createdAt: r.created_at })),
        })
      }
      if (req.method === 'POST' && path === '/chat') {
        const { text } = await req.json<{ text: string }>()
        if (!text?.trim()) return json({ error: 'empty' }, 400)
        return this.chat(text.trim().slice(0, 4000))
      }
      if (req.method === 'GET' && path === '/today') {
        return json(await this.today(url.searchParams.get('refresh') === '1'))
      }
      if (req.method === 'POST' && path === '/insights') {
        return json(await this.insights())
      }
      if (path === '/memories' && req.method === 'POST') {
        const { text, origin } = await req.json<{ text: string; origin?: string }>()
        return json(this.addMemory(text, origin ?? 'user'))
      }
      const mem = path.match(/^\/memories\/([\w-]+)$/)
      if (mem && req.method === 'PATCH') {
        const { text } = await req.json<{ text: string }>()
        this.sql.exec('UPDATE memories SET text = ? WHERE id = ?', text, mem[1])
        return json({ ok: true })
      }
      if (mem && req.method === 'DELETE') {
        this.sql.exec('DELETE FROM memories WHERE id = ?', mem[1])
        return json({ ok: true })
      }
      const item = path.match(/^\/lists\/([\w-]+)\/items\/([\w-]+)$/)
      if (item && req.method === 'PATCH') {
        const { done } = await req.json<{ done: boolean }>()
        this.sql.exec('UPDATE list_items SET done = ? WHERE id = ? AND list_id = ?', done ? 1 : 0, item[2], item[1])
        return json({ ok: true })
      }
      if (item && req.method === 'DELETE') {
        this.sql.exec('DELETE FROM list_items WHERE id = ? AND list_id = ?', item[2], item[1])
        return json({ ok: true })
      }
      const list = path.match(/^\/lists\/([\w-]+)$/)
      if (list && req.method === 'DELETE') {
        this.sql.exec('DELETE FROM list_items WHERE list_id = ?', list[1])
        this.sql.exec('DELETE FROM lists WHERE id = ?', list[1])
        return json({ ok: true })
      }
      const src = path.match(/^\/sources\/(\w+)$/)
      if (src && (SOURCE_IDS as readonly string[]).includes(src[1])) {
        const id = src[1] as SourceId
        if (req.method === 'PUT') {
          const { snapshot, shared } = await req.json<{ snapshot: unknown; shared?: boolean }>()
          const summary = summarize(id, snapshot)
          this.sql.exec(
            `INSERT INTO sources (id, snapshot, summary, shared, updated_at) VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET snapshot = excluded.snapshot, summary = excluded.summary,
             shared = COALESCE(?, sources.shared), updated_at = excluded.updated_at`,
            id, JSON.stringify(snapshot), summary, shared === false ? 0 : 1, Date.now(), shared == null ? null : shared ? 1 : 0,
          )
          return json({ id, summary })
        }
        if (req.method === 'PATCH') {
          const { shared } = await req.json<{ shared: boolean }>()
          this.sql.exec('UPDATE sources SET shared = ? WHERE id = ?', shared ? 1 : 0, id)
          return json({ ok: true })
        }
        if (req.method === 'DELETE') {
          this.sql.exec('DELETE FROM sources WHERE id = ?', id)
          return json({ ok: true })
        }
      }
      if (req.method === 'DELETE' && path === '/agent') {
        await this.ctx.storage.deleteAll()
        this.migrate()
        return json({ ok: true })
      }
      return json({ error: 'not found' }, 404)
    } catch (e) {
      console.error(e)
      return json({ error: (e as Error).message }, 500)
    }
  }
}
