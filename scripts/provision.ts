// Gives each writer its own sign-in on the context log. Run by the admin, who holds scripts/.env.local.
//   node provision.ts add <agent-id>          creates the user and writes agents/<id>.env (mode 600)
//   node provision.ts deactivate <agent-id>   bans the user and marks it inactive; its rows keep their author
//   node provision.ts list                    lists registered agents
// The id goes in the user's app_metadata, which only the secret key can set. Hand agents/<id>.env to
// its owner privately: it holds that writer's password, never the secret key.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'

process.loadEnvFile(new URL('.env.local', import.meta.url))
const { SUPABASE_URL: url, SUPABASE_SECRET_KEY: secretKey, SUPABASE_PUBLISHABLE_KEY: publishableKey } = process.env
if (!url || !secretKey || !publishableKey)
  throw new Error('scripts/.env.local needs SUPABASE_URL, SUPABASE_SECRET_KEY and SUPABASE_PUBLISHABLE_KEY')
const admin = createClient(url, secretKey, { auth: { persistSession: false, autoRefreshToken: false } })
const emailFor = (id: string): string => `${id}@agents.vbt-context.example.com`
const fileFor = (id: string): URL => new URL(`agents/${id}.env`, import.meta.url)

async function add(id: string): Promise<void> {
  const password = randomBytes(24).toString('base64url')
  const { data, error } = await admin.auth.admin.createUser({
    email: emailFor(id), password, email_confirm: true, app_metadata: { agent_id: id },
  })
  if (error) throw new Error(`create user ${id}: ${error.message}`)
  const { error: registerError } = await admin.from('agents').insert({ id, user_id: data.user.id })
  if (registerError) {
    await admin.auth.admin.deleteUser(data.user.id)
    throw new Error(`register ${id}: ${registerError.message} (the user was removed again)`)
  }
  mkdirSync(new URL('agents/', import.meta.url), { recursive: true })
  const lines = [`SUPABASE_URL=${url}`, `SUPABASE_PUBLISHABLE_KEY=${publishableKey}`, `CONTEXT_EMAIL=${emailFor(id)}`, `CONTEXT_PASSWORD=${password}`]
  writeFileSync(fileFor(id), `${lines.join('\n')}\n`, { mode: 0o600 })
  console.log(`added ${id}; its sign-in is in ${fileFor(id).pathname}`)
}

// Never deletes: the log's author column points at the registry row.
async function deactivate(id: string): Promise<void> {
  const { data, error } = await admin.from('agents').update({ active: false }).eq('id', id).select('user_id').single()
  if (error) throw new Error(`deactivate ${id}: ${error.message}`)
  const { error: banError } = await admin.auth.admin.updateUserById(data.user_id, { ban_duration: '876000h' })
  if (banError) throw new Error(`ban ${id}: ${banError.message} (the registry row is already inactive)`)
  rmSync(fileFor(id), { force: true })
  console.log(`deactivated ${id}`)
}

async function list(): Promise<void> {
  const { data, error } = await admin.from('agents').select('id, active, created_at').order('id')
  if (error) throw new Error(error.message)
  if (!data.length) console.log('no agents registered')
  for (const a of data) console.log(`${a.id}\t${a.active ? 'active' : 'inactive'}\t${a.created_at}`)
}

const [command, id] = process.argv.slice(2)
try {
  if (command === 'add' && id) await add(id)
  else if (command === 'deactivate' && id) await deactivate(id)
  else if (command === 'list') await list()
  else throw new Error('usage: node provision.ts add <agent-id> | deactivate <agent-id> | list')
} catch (err) {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
}
