// Connectors push structured snapshots from the phone. The server turns each into a
// compact text block for the prompt, so the model reads the user's day, not raw JSON.

export interface HealthDay {
  date: string // YYYY-MM-DD (local)
  steps?: number
  sleepHours?: number
  bedtime?: string // HH:mm local
  wakeTime?: string
  restingHR?: number
  activeEnergy?: number // kcal
}
export interface HealthSnapshot {
  days: HealthDay[]
  workouts?: { date: string; type: string; minutes: number }[]
}
export interface CalendarSnapshot {
  events: { title: string; start: string; end?: string; allDay?: boolean; location?: string; calendar?: string }[]
  reminders?: { title: string; due?: string; list?: string; overdue?: boolean }[]
}
export interface LocationSnapshot {
  lat: number
  lon: number
  place?: string // e.g. "Xuhui, Shanghai"
  timezone?: string
}

export const SOURCE_IDS = ['health', 'calendar', 'location'] as const
export type SourceId = (typeof SOURCE_IDS)[number]

const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN)
const round = (n: number, d = 0) => Math.round(n * 10 ** d) / 10 ** d

function minutesOf(hhmm?: string): number | undefined {
  if (!hhmm) return undefined
  const [h, m] = hhmm.split(':').map(Number)
  if (Number.isNaN(h)) return undefined
  // Treat early-morning bedtimes as "after midnight" so 01:20 averages later than 23:40.
  return (h < 12 ? h + 24 : h) * 60 + (m || 0)
}
function hhmmOf(mins: number): string {
  const m = Math.round(mins) % (24 * 60)
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
}

export function summarizeHealth(s: HealthSnapshot): string {
  const days = [...(s.days ?? [])].sort((a, b) => a.date.localeCompare(b.date))
  if (!days.length) return 'No health data yet.'
  const last7 = days.slice(-7)
  const prev = days.slice(-14, -7)
  const lines: string[] = []
  const steps7 = avg(last7.map(d => d.steps).filter((x): x is number => x != null))
  const stepsPrev = avg(prev.map(d => d.steps).filter((x): x is number => x != null))
  if (!Number.isNaN(steps7)) {
    let l = `Steps: ${Math.round(steps7)}/day this week`
    if (!Number.isNaN(stepsPrev)) l += ` (prev week ${Math.round(stepsPrev)})`
    lines.push(l)
  }
  const sleep7 = avg(last7.map(d => d.sleepHours).filter((x): x is number => x != null))
  if (!Number.isNaN(sleep7)) lines.push(`Sleep: ${round(sleep7, 1)} h/night this week`)
  const bed = last7.map(d => minutesOf(d.bedtime)).filter((x): x is number => x != null)
  if (bed.length) lines.push(`Usual bedtime: ~${hhmmOf(avg(bed))}`)
  const wake = last7.map(d => minutesOf(d.wakeTime)).filter((x): x is number => x != null).map(x => x - 24 * 60)
  if (wake.length) lines.push(`Usual wake: ~${hhmmOf(avg(wake))}`)
  const hr = avg(last7.map(d => d.restingHR).filter((x): x is number => x != null))
  if (!Number.isNaN(hr)) lines.push(`Resting HR: ${Math.round(hr)} bpm`)
  const last = days.at(-1)!
  const lastBits = [
    last.sleepHours != null ? `slept ${round(last.sleepHours, 1)} h` : '',
    last.bedtime ? `bed ${last.bedtime}` : '',
    last.steps != null ? `${last.steps} steps` : '',
  ].filter(Boolean)
  if (lastBits.length) lines.push(`Latest day (${last.date}): ${lastBits.join(', ')}`)
  const w = (s.workouts ?? []).slice(-5)
  if (w.length) lines.push(`Recent workouts: ${w.map(x => `${x.date} ${x.type} ${x.minutes}min`).join('; ')}`)
  return lines.join('\n')
}

export function summarizeCalendar(s: CalendarSnapshot): string {
  const lines: string[] = []
  const events = [...(s.events ?? [])].sort((a, b) => a.start.localeCompare(b.start)).slice(0, 25)
  if (events.length) {
    lines.push('Upcoming events:')
    for (const e of events) {
      const when = e.allDay ? `${e.start.slice(0, 10)} (all day)` : `${e.start.replace('T', ' ').slice(0, 16)}`
      lines.push(`- ${when} ${e.title}${e.location ? ` @ ${e.location}` : ''}`)
    }
  } else lines.push('No upcoming events in the next week.')
  const rem = (s.reminders ?? []).slice(0, 15)
  if (rem.length) {
    lines.push('Open reminders:')
    for (const r of rem) lines.push(`- ${r.title}${r.due ? ` (due ${r.due.slice(0, 16).replace('T', ' ')})` : ''}${r.overdue ? ' OVERDUE' : ''}`)
  }
  return lines.join('\n')
}

export function summarizeLocation(s: LocationSnapshot): string {
  return `Currently around ${s.place ?? `${round(s.lat, 2)}, ${round(s.lon, 2)}`}.`
}

export function summarize(id: SourceId, snapshot: unknown): string {
  switch (id) {
    case 'health':
      return summarizeHealth(snapshot as HealthSnapshot)
    case 'calendar':
      return summarizeCalendar(snapshot as CalendarSnapshot)
    case 'location':
      return summarizeLocation(snapshot as LocationSnapshot)
  }
}

// ---- Weather (Open-Meteo, no key) ----

const WMO: Record<number, string> = {
  0: 'clear', 1: 'mostly clear', 2: 'partly cloudy', 3: 'overcast', 45: 'fog', 48: 'fog',
  51: 'light drizzle', 53: 'drizzle', 55: 'heavy drizzle', 61: 'light rain', 63: 'rain', 65: 'heavy rain',
  71: 'light snow', 73: 'snow', 75: 'heavy snow', 80: 'showers', 81: 'showers', 82: 'violent showers',
  95: 'thunderstorm', 96: 'thunderstorm with hail', 99: 'thunderstorm with hail',
}

export interface WeatherReport {
  place: string
  text: string
  now?: { temp: number; condition: string }
}

export async function geocode(name: string): Promise<{ lat: number; lon: number; place: string } | null> {
  const u = new URL('https://geocoding-api.open-meteo.com/v1/search')
  u.searchParams.set('name', name)
  u.searchParams.set('count', '1')
  const r: any = await (await fetch(u)).json()
  const g = r.results?.[0]
  if (!g) return null
  return { lat: g.latitude, lon: g.longitude, place: [g.name, g.admin1, g.country].filter(Boolean).join(', ') }
}

export async function weather(lat: number, lon: number, place: string): Promise<WeatherReport> {
  const u = new URL('https://api.open-meteo.com/v1/forecast')
  u.searchParams.set('latitude', String(lat))
  u.searchParams.set('longitude', String(lon))
  u.searchParams.set('current', 'temperature_2m,weather_code')
  u.searchParams.set('daily', 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max')
  u.searchParams.set('forecast_days', '4')
  u.searchParams.set('timezone', 'auto')
  const r: any = await (await fetch(u)).json()
  const lines: string[] = []
  let now: WeatherReport['now']
  if (r.current) {
    now = { temp: Math.round(r.current.temperature_2m), condition: WMO[r.current.weather_code] ?? 'unknown' }
    lines.push(`Now in ${place}: ${now.temp}°C, ${now.condition}`)
  }
  const d = r.daily
  if (d?.time) {
    d.time.forEach((day: string, i: number) => {
      lines.push(
        `${day}: ${WMO[d.weather_code[i]] ?? '?'}, ${Math.round(d.temperature_2m_min[i])}–${Math.round(d.temperature_2m_max[i])}°C, rain ${d.precipitation_probability_max[i] ?? 0}%`,
      )
    })
  }
  return { place, text: lines.join('\n'), now }
}
