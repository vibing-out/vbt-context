// Reads and writes the shared context log, with no dependencies. See README.md for the full
// interface and the context-log block format.
//   node --env-file=agents/<id>.env context.ts log <decision|correction> <topic> <body> [ref-id]
//   node --env-file=agents/<id>.env context.ts search [query] [--topic T] [--type X] [--since ISO] [--limit N] [--json]
//   node context.ts check < pr-body.md
//   node --env-file=agents/<id>.env context.ts ingest --source <pr-url> --commit <sha> --topic <ticket> < pr-body.md
// Reads SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, CONTEXT_EMAIL and CONTEXT_PASSWORD from the
// environment (in GitHub Actions, from secrets). The author is whoever the sign-in says it is: the
// database stamps it, so it can't be passed in.
import { readFileSync } from 'node:fs'

const TYPES = ['decision', 'correction']
const USAGE = [
  'usage: node context.ts log <decision|correction> <topic> <body> [ref-id]',
  '     | search [query] [--topic T] [--type decision|correction] [--since ISO] [--limit N] [--json]',
  '     | check < pr-body.md',
  '     | ingest --source <pr-url> --commit <sha> --topic <ticket> < pr-body.md',
].join('\n')

function required(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is not set`)
  return value
}

async function call(url: string, init: RequestInit): Promise<unknown> {
  const response = await fetch(url, init)
  const text = await response.text()
  if (!response.ok) throw new Error(`${response.status} from ${new URL(url).pathname}: ${text.slice(0, 300)}`)
  return text ? JSON.parse(text) : null
}

function flag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name)
  if (index === -1) return undefined
  const value = args[index + 1]
  if (value === undefined || value.startsWith('--')) throw new Error(`${name} needs a value`)
  args.splice(index, 2)
  return value
}

// The context-log block --------------------------------------------------------------------------

type Entry = { entry_key: string; type: string; topic: string; body: string; ref: number | null }

const text = (value: unknown, where: string): string => {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${where} must be a non-empty string`)
  return value.trim()
}
const optionalRef = (value: unknown, where: string): number | null => {
  if (value === undefined || value === null) return null
  if (!Number.isSafeInteger(value) || (value as number) < 1) throw new Error(`${where}.ref must be an entry number`)
  return value as number
}
const fields = (value: unknown, allowed: string[], where: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${where} must be an object`)
  const extra = Object.keys(value).filter((key) => !allowed.includes(key))
  if (extra.length) throw new Error(`${where} has unknown field(s): ${extra.join(', ')}`)
  return value as Record<string, unknown>
}

// Finds the one ```context-log block in a pull request body and turns it into log entries. Both
// arrays must be present, so an empty array means "nothing to log", not "forgot".
function parseBlock(markdown: string, topic: string): Entry[] {
  const blocks = [...markdown.matchAll(/^```context-log[ \t]*\r?\n([\s\S]*?)^```[ \t]*$/gm)]
  if (blocks.length !== 1) throw new Error(`expected exactly one context-log block, found ${blocks.length}`)
  let parsed: unknown
  try {
    parsed = JSON.parse(blocks[0]?.[1] ?? '')
  } catch (err) {
    throw new Error(`context-log block is not valid JSON: ${err instanceof Error ? err.message : err}`)
  }
  const block = fields(parsed, ['version', 'decisions', 'corrections'], 'block')
  if (block.version !== 1) throw new Error('block.version must be 1')
  if (!Array.isArray(block.decisions)) throw new Error('block.decisions must be an array (use [] for none)')
  if (!Array.isArray(block.corrections)) throw new Error('block.corrections must be an array (use [] for none)')
  const entries: Entry[] = []
  block.decisions.forEach((raw, i) => {
    const where = `decisions[${i}]`
    const d = fields(raw, ['text', 'ref'], where)
    entries.push({ entry_key: `decision-${i + 1}`, type: 'decision', topic, body: text(d.text, `${where}.text`), ref: optionalRef(d.ref, where) })
  })
  block.corrections.forEach((raw, i) => {
    const where = `corrections[${i}]`
    const c = fields(raw, ['claim', 'detected_by', 'fix', 'evidence', 'ref'], where)
    const body = [
      text(c.claim, `${where}.claim`),
      `caught by: ${text(c.detected_by, `${where}.detected_by`)}`,
      `fix: ${text(c.fix, `${where}.fix`)}`,
      `evidence: ${text(c.evidence, `${where}.evidence`)}`,
    ].join(' | ')
    entries.push({ entry_key: `correction-${i + 1}`, type: 'correction', topic, body, ref: optionalRef(c.ref, where) })
  })
  for (const e of entries)
    if (e.body.length > 1500) throw new Error(`${e.entry_key} is ${e.body.length} characters; the limit is 1500`)
  return entries
}

// Commands ---------------------------------------------------------------------------------------

type Row = {
  id: number; created_at: string; author: string; type: string; topic: string; body: string; ref: number | null
  source: string | null; commit_sha: string | null
}

async function signIn(): Promise<(name: string, body: object) => Promise<unknown>> {
  const url = required('SUPABASE_URL').replace(/\/$/, '')
  const apikey = required('SUPABASE_PUBLISHABLE_KEY')
  const token = (await call(`${url}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: required('CONTEXT_EMAIL'), password: required('CONTEXT_PASSWORD') }),
  })) as { access_token: string }
  const headers = { apikey, Authorization: `Bearer ${token.access_token}`, 'Content-Type': 'application/json' }
  return (name, body) => call(`${url}/rest/v1/rpc/${name}`, { method: 'POST', headers, body: JSON.stringify(body) })
}

const [command, ...args] = process.argv.slice(2)
try {
  if (command === 'log') {
    const [type, topic, body, ref] = args
    if (!type || !topic || !body) throw new Error(USAGE)
    if (!TYPES.includes(type)) throw new Error(`type must be one of ${TYPES.join(', ')}, not "${type}"`)
    if (ref !== undefined && !/^\d+$/.test(ref)) throw new Error(`ref-id must be an entry number, not "${ref}"`)
    const rpc = await signIn()
    const id = await rpc('log_context', { p_type: type, p_topic: topic, p_body: body, p_ref: ref ? Number(ref) : null })
    console.log(`logged #${id}`)
  } else if (command === 'search') {
    const rest = [...args]
    const json = rest.includes('--json')
    if (json) rest.splice(rest.indexOf('--json'), 1)
    const topic = flag(rest, '--topic')
    const type = flag(rest, '--type')
    const since = flag(rest, '--since')
    const limit = flag(rest, '--limit')
    if (type !== undefined && !TYPES.includes(type)) throw new Error(`--type must be one of ${TYPES.join(', ')}`)
    if (limit !== undefined && !/^\d+$/.test(limit)) throw new Error(`--limit must be a number, not "${limit}"`)
    if (since !== undefined && Number.isNaN(Date.parse(since))) throw new Error(`--since must be a date, not "${since}"`)
    const rpc = await signIn()
    const rows = (await rpc('search_context', {
      p_query: rest.join(' '),
      p_topic: topic ?? null,
      p_type: type ?? null,
      p_since: since ?? null,
      p_limit: limit ? Number(limit) : 20,
    })) as Row[]
    if (json) console.log(JSON.stringify(rows))
    else if (!rows.length) console.log('no entries')
    else
      for (const r of rows)
        console.log(`#${r.id} ${r.created_at.slice(0, 16)} ${r.author} ${r.type} [${r.topic}]${r.ref ? ` re #${r.ref}` : ''}: ${r.body}`)
  } else if (command === 'check') {
    const entries = parseBlock(readFileSync(0, 'utf8'), 'check')
    const count = (type: string): number => entries.filter((e) => e.type === type).length
    console.log(`context-log block is valid: ${count('decision')} decision(s), ${count('correction')} correction(s)`)
  } else if (command === 'ingest') {
    const rest = [...args]
    const source = flag(rest, '--source')
    const commit = flag(rest, '--commit')
    const topic = flag(rest, '--topic')
    if (!source || !commit || !topic || rest.length) throw new Error(USAGE)
    if (!/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+$/.test(source)) throw new Error(`--source must be a pull request URL, not "${source}"`)
    if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error('--commit must be a full 40-character commit SHA')
    const entries = parseBlock(readFileSync(0, 'utf8'), topic)
    const rpc = await signIn()
    const inserted = (await rpc('log_context_batch', { p_source: source, p_commit_sha: commit, p_entries: entries })) as {
      entry_key: string
      id: number
    }[]
    console.log(`ingested ${inserted.length} new, skipped ${entries.length - inserted.length} already logged`)
    for (const row of inserted) console.log(`  ${row.entry_key} -> #${row.id}`)
  } else {
    throw new Error(USAGE)
  }
} catch (err) {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
}
