// Accounts for the iOS app, modelled on Bower's sign-in:
// - Apple: native sheet on the phone → identity token → POST /v1/auth/apple (verified against Apple's JWKS).
// - Email: 6-digit code → POST /v1/auth/email/start, then /v1/auth/email/verify. New emails become new users.
//   TEST_ACCOUNT_EMAIL always takes TEST_ACCOUNT_CODE and gets no email (UI tests, App Review).
// Every user owns one cloud agent: a Companion Durable Object addressed by users.agent_id.
// Sessions are opaque bearer tokens; only their SHA-256 is stored.

export interface AuthEnv {
  DB: D1Database
  EMAIL?: SendEmail
  APPLE_BUNDLE_ID: string
  MAIL_FROM: string
  TEST_ACCOUNT_EMAIL?: string
  TEST_ACCOUNT_CODE?: string
}

export interface User {
  id: string
  agent_id: string
  email: string | null
  apple_sub: string | null
  name: string | null
  created_at: number
}

const CODE_TTL_MS = 10 * 60 * 1000
const CODE_RESEND_MS = 30 * 1000
const MAX_ATTEMPTS = 5

const enc = new TextEncoder()

async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', enc.encode(s))
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('')
}

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)
  return Uint8Array.from(atob(pad), c => c.charCodeAt(0))
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

export class AuthError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

const normalizeEmail = (e: string) => e.trim().toLowerCase()
const isEmail = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) && e.length <= 254

function isTestAccount(env: AuthEnv, email: string) {
  return !!env.TEST_ACCOUNT_EMAIL && !!env.TEST_ACCOUNT_CODE && email === normalizeEmail(env.TEST_ACCOUNT_EMAIL)
}

// ---------- users & sessions ----------

async function createUser(env: AuthEnv, fields: { email?: string | null; apple_sub?: string | null; name?: string | null }): Promise<User> {
  const user: User = {
    id: crypto.randomUUID(),
    agent_id: `agent_${crypto.randomUUID().replace(/-/g, '')}`,
    email: fields.email ?? null,
    apple_sub: fields.apple_sub ?? null,
    name: fields.name ?? null,
    created_at: Date.now(),
  }
  await env.DB.prepare('INSERT INTO users (id, agent_id, email, apple_sub, name, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(user.id, user.agent_id, user.email, user.apple_sub, user.name, user.created_at)
    .run()
  return user
}

async function createSession(env: AuthEnv, userId: string): Promise<string> {
  const token = b64url(crypto.getRandomValues(new Uint8Array(32)))
  const now = Date.now()
  await env.DB.prepare('INSERT INTO sessions (token_hash, user_id, created_at, last_seen_at) VALUES (?, ?, ?, ?)')
    .bind(await sha256(token), userId, now, now)
    .run()
  return token
}

export async function userFromBearer(env: AuthEnv, header: string | null): Promise<User | null> {
  const token = header?.replace(/^Bearer\s+/i, '').trim()
  if (!token || token.length < 20) return null
  const hash = await sha256(token)
  const user = await env.DB.prepare(
    'SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?',
  ).bind(hash).first<User>()
  if (user) {
    // Touch at most hourly so reads stay cheap.
    await env.DB.prepare('UPDATE sessions SET last_seen_at = ? WHERE token_hash = ? AND last_seen_at < ?')
      .bind(Date.now(), hash, Date.now() - 3600_000)
      .run()
  }
  return user
}

export async function signOut(env: AuthEnv, header: string | null) {
  const token = header?.replace(/^Bearer\s+/i, '').trim()
  if (token) await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await sha256(token)).run()
}

export async function deleteUser(env: AuthEnv, user: User) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM users WHERE id = ?').bind(user.id),
  ])
}

export function publicUser(u: User) {
  return { id: u.id, email: u.email, name: u.name, appleLinked: !!u.apple_sub, createdAt: u.created_at }
}

// ---------- email codes ----------

export async function startEmail(env: AuthEnv, rawEmail: string) {
  const email = normalizeEmail(rawEmail)
  if (!isEmail(email)) throw new AuthError(400, 'Enter a valid email address.')
  const existing = await env.DB.prepare('SELECT sent_at FROM email_codes WHERE email = ?').bind(email).first<{ sent_at: number }>()
  if (existing && Date.now() - existing.sent_at < CODE_RESEND_MS) {
    throw new AuthError(429, 'A code was just sent. Wait a few seconds before asking again.')
  }
  const code = isTestAccount(env, email)
    ? env.TEST_ACCOUNT_CODE!
    : String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, '0')
  const now = Date.now()
  await env.DB.prepare(
    `INSERT INTO email_codes (email, code_hash, expires_at, attempts, sent_at) VALUES (?, ?, ?, 0, ?)
     ON CONFLICT(email) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0, sent_at = excluded.sent_at`,
  ).bind(email, await sha256(`${email}:${code}`), now + CODE_TTL_MS, now).run()

  if (isTestAccount(env, email)) return
  await sendCode(env, email, code)
}

async function sendCode(env: AuthEnv, email: string, code: string) {
  const subject = `${code} is your Aibo code`
  const text = `Your Aibo sign-in code is ${code}. It expires in 10 minutes.\n\nIf you didn't ask for it, you can ignore this email.`
  if (!env.EMAIL) {
    console.log(`[auth] no EMAIL binding; code for ${email}: ${code}`)
    return
  }
  try {
    await env.EMAIL.send({ from: env.MAIL_FROM, to: email, subject, text })
  } catch (e) {
    // Sender domain not enabled yet: keep sign-in usable for whoever can read the logs.
    console.error(`[auth] email send failed for ${email}: ${(e as Error).message}; code: ${code}`)
    throw new AuthError(503, "We couldn't send the email right now. Try Sign in with Apple, or again later.")
  }
}

export async function verifyEmail(env: AuthEnv, rawEmail: string, code: string): Promise<{ token: string; user: User; isNew: boolean }> {
  const email = normalizeEmail(rawEmail)
  const row = await env.DB.prepare('SELECT * FROM email_codes WHERE email = ?')
    .bind(email)
    .first<{ code_hash: string; expires_at: number; attempts: number }>()
  if (!row || row.expires_at < Date.now()) throw new AuthError(400, 'That code has expired. Ask for a new one.')
  if (row.attempts >= MAX_ATTEMPTS) throw new AuthError(429, 'Too many tries. Ask for a new code.')
  const ok = safeEqual(row.code_hash, await sha256(`${email}:${String(code).trim()}`))
  if (!ok) {
    await env.DB.prepare('UPDATE email_codes SET attempts = attempts + 1 WHERE email = ?').bind(email).run()
    throw new AuthError(400, "That code isn't right.")
  }
  await env.DB.prepare('DELETE FROM email_codes WHERE email = ?').bind(email).run()

  let user = await env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(email).first<User>()
  const isNew = !user
  if (!user) user = await createUser(env, { email })
  return { token: await createSession(env, user.id), user, isNew }
}

// ---------- Sign in with Apple ----------

let jwksCache: { keys: (JsonWebKey & { kid: string })[]; at: number } | null = null

async function appleKeys() {
  if (jwksCache && Date.now() - jwksCache.at < 3600_000) return jwksCache.keys
  const res = await fetch('https://appleid.apple.com/auth/keys')
  if (!res.ok) throw new AuthError(502, "Couldn't reach Apple. Try again.")
  const body = await res.json<{ keys: (JsonWebKey & { kid: string })[] }>()
  jwksCache = { keys: body.keys, at: Date.now() }
  return body.keys
}

interface AppleClaims {
  iss: string
  aud: string
  exp: number
  sub: string
  email?: string
  email_verified?: boolean | string
}

async function verifyAppleToken(env: AuthEnv, idToken: string): Promise<AppleClaims> {
  const [h, p, s] = idToken.split('.')
  if (!h || !p || !s) throw new AuthError(400, 'Malformed Apple token.')
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(h))) as { kid: string; alg: string }
  if (header.alg !== 'RS256') throw new AuthError(400, 'Unexpected Apple token.')
  const jwk = (await appleKeys()).find(k => k.kid === header.kid)
  if (!jwk) throw new AuthError(400, 'Unknown Apple signing key.')
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify'])
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlDecode(s), enc.encode(`${h}.${p}`))
  if (!valid) throw new AuthError(401, 'Apple token signature is invalid.')
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(p))) as AppleClaims
  if (claims.iss !== 'https://appleid.apple.com') throw new AuthError(401, 'Apple token issuer mismatch.')
  if (claims.aud !== env.APPLE_BUNDLE_ID) throw new AuthError(401, 'Apple token is for another app.')
  if (claims.exp * 1000 < Date.now()) throw new AuthError(401, 'Apple token expired.')
  return claims
}

export async function signInWithApple(env: AuthEnv, idToken: string, name?: string | null) {
  let claims: AppleClaims
  try {
    claims = await verifyAppleToken(env, idToken)
  } catch (e) {
    if (e instanceof AuthError) throw e
    throw new AuthError(400, 'Malformed Apple token.')
  }
  const email = claims.email ? normalizeEmail(claims.email) : null
  let user = await env.DB.prepare('SELECT * FROM users WHERE apple_sub = ?').bind(claims.sub).first<User>()
  let isNew = false
  if (!user && email) {
    // Same verified email from Apple and from an email code lands on one account.
    user = await env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(email).first<User>()
    if (user) {
      await env.DB.prepare('UPDATE users SET apple_sub = ? WHERE id = ?').bind(claims.sub, user.id).run()
      user.apple_sub = claims.sub
    }
  }
  if (!user) {
    user = await createUser(env, { email, apple_sub: claims.sub, name: name?.trim() || null })
    isNew = true
  } else if (name?.trim() && !user.name) {
    await env.DB.prepare('UPDATE users SET name = ? WHERE id = ?').bind(name.trim(), user.id).run()
    user.name = name.trim()
  }
  return { token: await createSession(env, user.id), user, isNew }
}
