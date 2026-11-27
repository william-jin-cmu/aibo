import { AuthError, deleteUser, publicUser, signInWithApple, signOut, startEmail, userFromBearer, verifyEmail } from './auth'
import { Companion, type Env } from './companion'

export { Companion }

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })

async function body<T>(req: Request): Promise<T> {
  try {
    return await req.json<T>()
  } catch {
    throw new AuthError(400, 'Invalid JSON body.')
  }
}

function agentOf(env: Env, agentId: string) {
  return env.COMPANION.get(env.COMPANION.idFromName(agentId))
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url)
    const path = url.pathname
    try {
      if (path === '/health') return json({ ok: true })

      // ---- sign-in (no session needed) ----
      if (req.method === 'POST' && path === '/v1/auth/email/start') {
        const { email } = await body<{ email: string }>(req)
        await startEmail(env, email ?? '')
        return json({ ok: true })
      }
      if (req.method === 'POST' && path === '/v1/auth/email/verify') {
        const { email, code } = await body<{ email: string; code: string }>(req)
        const r = await verifyEmail(env, email ?? '', code ?? '')
        return json({ token: r.token, user: publicUser(r.user), isNew: r.isNew })
      }
      if (req.method === 'POST' && path === '/v1/auth/apple') {
        const { identityToken, name } = await body<{ identityToken: string; name?: string }>(req)
        if (!identityToken) throw new AuthError(400, 'Missing Apple identity token.')
        const r = await signInWithApple(env, identityToken, name)
        return json({ token: r.token, user: publicUser(r.user), isNew: r.isNew })
      }

      if (!path.startsWith('/v1/')) return json({ error: 'not found' }, 404)

      // ---- everything else needs a session ----
      const auth = req.headers.get('Authorization')
      const user = await userFromBearer(env, auth)
      if (!user) return json({ error: 'unauthorized' }, 401)

      if (req.method === 'GET' && path === '/v1/auth/me') return json({ user: publicUser(user) })
      if (req.method === 'POST' && path === '/v1/auth/signout') {
        await signOut(env, auth)
        return json({ ok: true })
      }
      if (req.method === 'DELETE' && path === '/v1/account') {
        // Wipe the agent first, then the account itself.
        await agentOf(env, user.agent_id).fetch(new Request('https://agent/v1/agent', { method: 'DELETE' }))
        await deleteUser(env, user)
        return json({ ok: true })
      }

      // The user's own cloud agent handles the rest.
      const fwd = new Request(req)
      fwd.headers.set('X-Account-Name', user.name ?? '')
      return agentOf(env, user.agent_id).fetch(fwd)
    } catch (e) {
      if (e instanceof AuthError) return json({ error: e.message }, e.status)
      console.error(e)
      return json({ error: 'Something went wrong.' }, 500)
    }
  },
} satisfies ExportedHandler<Env>
