# vbt-context

The shared context log for the VBT build at Indy Init 2026. It has two jobs:

1. **Cross-ticket decisions.** A later ticket learns what an earlier one decided (for example, T-08 learns T-02's status names).
2. **AI-correction record.** Every place the AI was wrong, and how it was caught, for the judges.

Code writes and reads the log, not agents. The factory's GitHub Actions dispatch script ingests a `context-log` block from each merged pull request, and posts earlier entries on a ticket before marking it ready. Warp agents need no log credentials: one `factory-dispatch` identity lives in GitHub Actions secrets.

## What is here

| Path | What it does |
|---|---|
| `supabase/migrations/20261107000000_context_log.sql` | The `agents` registry, the insert-only `context_log` table, its write functions `log_context()` and `log_context_batch()`, `search_context()`, Row Level Security, grants and the triggers that block edits, deletes and `TRUNCATE` |
| `scripts/context.ts` | Zero-dependency command-line tool: `log`, `search`, `check`, `ingest` |
| `scripts/provision.ts` | Admin tool: `add`, `deactivate`, `list` writer identities |
| `scripts/verify.sh` | Live check of every guarantee below against the linked project. Its test rows all use `verify-` topics and only those are cleaned up, so it is safe to run on a log with real entries |

## The data model

- **Types:** `decision` and `correction` only. A `correction` means "the AI got something wrong, and this is the fix". It needs no `ref`.
- **Author:** stamped by the database from the caller's sign-in. There is no way to pass it in.
- **Insert-only:** callers have no update, delete or insert grant on the table, and a trigger refuses updates and deletes for everyone but the project's admin roles. `TRUNCATE` is refused for everyone.
- **Replacing a row:** log a new row with `ref` set to the old row's id. `search_context()` returns only current rows: a row that a later row's `ref` points to is left out.
- **Ingested rows** carry `source` (the pull request URL), `commit_sha` (the merge commit) and `entry_key`. The pair (`source`, `entry_key`) is unique, and duplicates are skipped, so re-running ingestion never double-logs.
- **Identities** are deactivated, never deleted, so log rows keep their author.

## Command-line interface (`scripts/context.ts`)

Needs Node 24 or later. Sign-in comes from the environment: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `CONTEXT_EMAIL`, `CONTEXT_PASSWORD`. Locally, pass an identity file with `--env-file`. In GitHub Actions, set them from secrets. Every command exits 1 with a message on stderr when it fails.

```
node --env-file=agents/<id>.env context.ts log <decision|correction> <topic> <body> [ref-id]
    prints: logged #<id>

node --env-file=agents/<id>.env context.ts search [query] [--topic T] [--type decision|correction] [--since ISO] [--limit N] [--json]
    prints one line per current row, newest first:
      #<id> <created_at> <author> <type> [<topic>] re #<ref>: <body>
    --json prints the rows as a JSON array of
      {id, created_at, author, type, topic, body, ref, source, commit_sha}
    the query is full-text (websearch syntax); --limit defaults to 20, maximum 100

node context.ts check < pr-body.md
    validates the pull request body's context-log block; no sign-in needed
    prints: context-log block is valid: <n> decision(s), <m> correction(s)

node --env-file=agents/<id>.env context.ts ingest --source <pr-url> --commit <merge-sha> --topic <ticket-id> < pr-body.md
    validates the block, then logs all its entries in one transaction (all or none)
    prints: ingested <n> new, skipped <m> already logged
            and one "  <entry_key> -> #<id>" line per new row
```

Conventions: `topic` is the ticket id (`T-02`), so a later ticket can pull a blocker's entries with `search --topic T-02`. `--source` must be `https://github.com/<owner>/<repo>/pull/<n>` and `--commit` a full 40-character SHA.

## The `context-log` block (version 1)

Each epic pull request body carries exactly one fenced block:

````
```context-log
{
  "version": 1,
  "decisions": [
    { "text": "Ticket statuses are draft, ready, in_progress, done" },
    { "text": "Statuses also include blocked", "ref": 12 }
  ],
  "corrections": [
    {
      "claim": "Agent said the status column was an enum; it is text with a check constraint",
      "detected_by": "code reviewer",
      "fix": "Changed the type guard to read the check constraint values",
      "evidence": "review comment on src/status.ts line 14"
    }
  ]
}
```
````

Rules, all enforced by `check` and `ingest`:

- Exactly one block. `version` is `1`. Both `decisions` and `corrections` are present; use `[]` for none, so "nothing to log" is different from "forgot".
- A decision is `{text, ref?}`. A correction is `{claim, detected_by, fix, evidence, ref?}`, all non-empty strings. No other fields.
- `ref` (optional) is the id of an earlier log row this entry replaces.
- Entry keys are positional: `decision-1`, `decision-2`, …, `correction-1`, …. A correction's body is stored as `claim | caught by: … | fix: … | evidence: …`, at most 1500 characters.

## Admin setup

1. Put the project's URL, secret key and publishable key in `scripts/.env.local` (git-ignored) as `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `SUPABASE_PUBLISHABLE_KEY`.
2. `supabase link --project-ref <ref>`, then `supabase db push`.
3. `cd scripts && npm install`, then `node provision.ts add <id>` for each writer: `factory-dispatch`, `austin-claude`, `shawn-claude`. Each writes `scripts/agents/<id>.env` (mode 600, git-ignored).
4. The four values in `agents/factory-dispatch.env` become GitHub Actions secrets in `vibing-out/vbt`. People's files are handed out privately.
5. To retire a writer: `node provision.ts deactivate <id>`. It bans the sign-in and marks the registry row inactive; it never deletes.

Test rows can be removed only with the secret key (the `service_role`), through the REST API or the SQL editor.
