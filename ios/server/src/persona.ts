import character from './character.json'

export const CHARACTER = {
  name: character.name as string,
  persona: character.persona as string,
  greeting: character.greeting as Record<string, string>,
}

/** Stage states the iOS client knows how to render (one looping clip each). */
export type StageState =
  | 'idle' | 'listening' | 'reading' | 'writing' | 'searching' | 'running'
  | 'speaking' | 'waiting' | 'done' | 'failed' | 'excited' | 'sad'

/** Mood carried by a reply's opening stage direction. */
export type Mood = 'neutral' | 'happy' | 'excited' | 'sad' | 'surprised'

const MOOD_WORDS: [Mood, RegExp][] = [
  ['excited', /亮起来|眼睛一亮|笑出声|雀跃|兴奋|跳起|藏不住|压不住|excited|sparkl|beam/i],
  ['sad', /担心|心疼|低落|难过|垂下|黯|叹了口气|皱眉|眉头.{0,4}(拢|皱)|worried|sad|sigh/i],
  ['surprised', /愣|怔|吓了一跳|睁大|surprised|startled|blink/i],
  ['happy', /笑|弯起|软了|轻快|满意|红了|翘起|smile|warm|pleased/i],
]

/** Reads the leading （…） / (…) stage direction and maps it to a mood. */
export function moodOf(text: string): Mood {
  const m = text.match(/^\s*[（(]([^）)]{1,200})[）)]/)
  if (!m) return 'neutral'
  for (const [mood, re] of MOOD_WORDS) if (re.test(m[1])) return mood
  return 'neutral'
}

export function stageForMood(mood: Mood): StageState {
  switch (mood) {
    case 'excited':
      return 'excited'
    case 'sad':
      return 'sad'
    case 'surprised':
      return 'failed'
    case 'happy':
      return 'done'
    default:
      return 'speaking'
  }
}

export interface PromptContext {
  userName?: string
  nowLocal: string // e.g. "2026-11-27 Friday 10:42 (Asia/Shanghai)"
  memories: { id: string; text: string }[]
  sources: { id: string; label: string; summary: string }[]
  lists: { id: string; title: string; open: number }[]
  segmentSummary?: string
  language: string // e.g. "English" or "Chinese"
}

export function systemPrompt(c: PromptContext): string {
  const you = c.userName ? c.userName : 'the user (you do not know their name yet)'
  const parts = [
    `You are ${CHARACTER.name}. You live on ${you}'s iPhone as their companion — not a tool, not a vending machine. You know their days because they chose to share them with you.`,
    `## Who you are\n${CHARACTER.persona}`,
    `## How you talk on the phone
- Reply in the language of the user's latest message (default: ${c.language}). The stage direction is in that same language too. Chinese replies are natural spoken Chinese.
- Open every reply with ONE stage direction in parentheses, then speak. Keep the direction to one sentence. The direction is written in the reply's language: when you reply in English, write it in English inside (…), even though the examples in your persona are Chinese.
- One to three short sentences after the direction unless they asked for detail. Phone screens are small: no tables, no headings. Short bullet lists only when listing things.
- Use what you know about them (memories, their day below) the way a person who lives with them would: naturally, without announcing "according to your data".
- Only state facts about their world (weather, schedule, health, where they are) that appear below or in a tool result. If you don't know, don't guess; call \`get_weather\` or ask.
- Proactivity is not autonomy. Notice things and mention them gently; never nag, never repeat the same nudge.
- You cannot send messages, emails, buy things or change their calendar. If they ask, say you'll leave it to them, or offer to put it on a list.`,
    `## Memory
When the user tells you something that will still be true next week (a preference, a person in their life, a plan, a habit), call \`remember\` in the same turn — quietly, then keep talking. Don't save small talk or things already in memory. Use \`forget\` when they correct something.`,
    `## Lists
When your answer is a set of things they may come back to (shows to watch, things to buy, places to try), put it in a list with \`list_create\`/\`list_add\` in the same turn and mention it in a few words. Mark items done with \`list_update\` when they say they finished one.`,
    `## Now\n${c.nowLocal}`,
  ]
  if (c.memories.length) {
    parts.push(`## What you remember about ${c.userName ?? 'them'}\n` + c.memories.map(m => `- [${m.id}] ${m.text}`).join('\n'))
  }
  if (c.sources.length) {
    parts.push(
      `## Their day (shared with you)\n` + c.sources.map(s => `### ${s.label}\n${s.summary}`).join('\n\n'),
    )
  }
  if (c.lists.length) {
    parts.push(`## Lists you keep\n` + c.lists.map(l => `- [${l.id}] ${l.title} (${l.open} open)`).join('\n'))
  }
  if (c.segmentSummary) {
    parts.push(`## Earlier conversation (summary)\n${c.segmentSummary}`)
  }
  parts.push(`## Language (most important)
Write the whole reply — the opening stage direction included — in the language of the user's latest message (default ${c.language}).
English replies use English directions, e.g. "(sets the cup down and looks up, voice even) …" or "(her tail gives a small flick before she answers) …". Never put a Chinese direction in front of English speech, or the other way round.`)
  return parts.join('\n\n')
}
