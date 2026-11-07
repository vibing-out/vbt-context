#!/usr/bin/env bash
# Live verification of the context log against the linked project. Run from anywhere:
#   bash scripts/verify.sh
# Needs scripts/.env.local, agents/austin-claude.env and agents/factory-dispatch.env, and the repo
# linked with `supabase link`. Every test row uses a topic starting with "verify-", and cleanup
# deletes only those rows, so it is safe to run against a log that holds real entries. It creates
# and removes two throwaway sign-ins and a throwaway agent, verify-temp.
set -u
cd "$(dirname "$0")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
set -a; . ./.env.local; set +a
A="--env-file=agents/austin-claude.env"
F="--env-file=agents/factory-dispatch.env"
REST="$SUPABASE_URL/rest/v1"
hr() { echo; echo "=== $*"; }
token() { # $1 env file -> access token
  ( set -a; . "$1"; set +a
    curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" -H "apikey: $SUPABASE_PUBLISHABLE_KEY" -H 'Content-Type: application/json' \
      -d "{\"email\":\"$CONTEXT_EMAIL\",\"password\":\"$CONTEXT_PASSWORD\"}" | node -pe 'JSON.parse(require("fs").readFileSync(0)).access_token' )
}
asuser() { # $1 token, rest curl args
  local t=$1; shift
  curl -s -w ' [HTTP %{http_code}]' -H "apikey: $SUPABASE_PUBLISHABLE_KEY" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$@"; echo
}
anon() { curl -s -w ' [HTTP %{http_code}]' -H "apikey: $SUPABASE_PUBLISHABLE_KEY" -H 'Content-Type: application/json' "$@"; echo; }
sql() { (cd .. && supabase db query --remote --yes "$1" -o json 2>&1 | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s.slice(s.indexOf("{")));console.log(JSON.stringify(j.rows??j.error??j))}catch{console.log(s.trim().split("\n").slice(-3).join(" "))}})'); }

AT=$(token agents/austin-claude.env)

hr "1. log decision, search finds it with author austin-claude"
OUT=$(node $A context.ts log decision verify-T-02 "statuses are draft, ready, in_progress, done"); echo "$OUT"
D1=$(echo "$OUT" | sed 's/logged #//')
node $A context.ts search statuses --topic verify-T-02

hr "2. correction with no ref; a row with ref shows re #id"
node $A context.ts log correction verify-T-05 "reviewer caught the agent using an enum where the column is text"
OUT=$(node $A context.ts log decision verify-T-02 "statuses are draft, ready, in_progress, blocked, done" "$D1"); echo "$OUT"
D2=$(echo "$OUT" | sed 's/logged #//')
node $A context.ts search --topic verify-T-02

hr "3. author cannot be spoofed: extra p_author argument, direct insert"
asuser "$AT" "$REST/rpc/log_context" -d '{"p_type":"decision","p_topic":"verify-T-99","p_body":"spoof","p_author":"factory-dispatch"}'
asuser "$AT" "$REST/context_log" -d '{"author":"factory-dispatch","type":"decision","topic":"verify-T-99","body":"spoof"}'

hr "4a. insert-only by permission: update and delete through REST as austin-claude"
asuser "$AT" -X PATCH "$REST/context_log?id=eq.$D1" -d '{"body":"edited"}'
asuser "$AT" -X DELETE "$REST/context_log?id=eq.$D1"
hr "4b. insert-only by trigger: grant update/delete and open policies in a rolled-back transaction"
sql "begin; grant update, delete on public.context_log to authenticated; create policy t_sel on public.context_log for select to authenticated using (true); create policy t_upd on public.context_log for update to authenticated using (true); set local role authenticated; update public.context_log set body = 'edited' where id = $D1; rollback;"
sql "begin; grant update, delete on public.context_log to authenticated; create policy t_sel on public.context_log for select to authenticated using (true); create policy t_del on public.context_log for delete to authenticated using (true); set local role authenticated; delete from public.context_log where id = $D1; rollback;"

hr "5. anonymous callers: read table, call search and log"
anon "$REST/context_log?select=id"
anon "$REST/rpc/search_context" -d '{}'
anon "$REST/rpc/log_context" -d '{"p_type":"decision","p_topic":"verify-T-99","p_body":"anon"}'

hr "6. unregistered user, and a user claiming another agent's id"
SK="$SUPABASE_SECRET_KEY"
mk() { curl -s "$SUPABASE_URL/auth/v1/admin/users" -H "apikey: $SK" -H "Authorization: Bearer $SK" -H 'Content-Type: application/json' -d "$1" | node -pe 'JSON.parse(require("fs").readFileSync(0)).id'; }
U1=$(mk '{"email":"stranger@agents.vbt-context.example.com","password":"verify-Stranger-1234","email_confirm":true}')
U2=$(mk '{"email":"impostor@agents.vbt-context.example.com","password":"verify-Impostor-1234","email_confirm":true,"app_metadata":{"agent_id":"austin-claude"}}')
cat > "$TMP/u1.env" <<EOF
SUPABASE_URL=$SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY
CONTEXT_EMAIL=stranger@agents.vbt-context.example.com
CONTEXT_PASSWORD=verify-Stranger-1234
EOF
sed 's/stranger/impostor/; s/Stranger/Impostor/' "$TMP/u1.env" > "$TMP/u2.env"
echo "stranger:"; node --env-file="$TMP/u1.env" context.ts log decision verify-T-99 "stranger write"
echo "stranger search:"; node --env-file="$TMP/u1.env" context.ts search
echo "impostor:"; node --env-file="$TMP/u2.env" context.ts log decision verify-T-99 "impostor write"
hr "6b. deactivated agent: an old token stops working once the row is inactive"
node provision.ts add verify-temp >/dev/null
TT=$(token agents/verify-temp.env)
asuser "$TT" "$REST/rpc/log_context" -d '{"p_type":"decision","p_topic":"verify-T-98","p_body":"before deactivation"}'
node provision.ts deactivate verify-temp
asuser "$TT" "$REST/rpc/log_context" -d '{"p_type":"decision","p_topic":"verify-T-98","p_body":"after deactivation"}'
node provision.ts list

hr "7. type limits"
node $A context.ts log note verify-T-99 "a note"
asuser "$AT" "$REST/rpc/log_context" -d '{"p_type":"handoff","p_topic":"verify-T-99","p_body":"a handoff"}'

hr "8. factory-dispatch writes, rows show that author (ingest a pull request block)"
BODY=$'## Summary\nstuff\n\n```context-log\n{"version":1,"decisions":[{"text":"badge colors come from the status map"}],"corrections":[{"claim":"agent assumed a 0-based ticket index","detected_by":"unit test","fix":"switched to 1-based","evidence":"test/status.test.ts"}]}\n```\n'
SRC=https://github.com/vibing-out/verify-only/pull/1
SHA=0123456789abcdef0123456789abcdef01234567
printf '%s' "$BODY" | node context.ts check
printf '%s' "$BODY" | node $F context.ts ingest --source $SRC --commit $SHA --topic verify-T-07
node $A context.ts search --topic verify-T-07

hr "extra: duplicate skip (same pull request ingested again)"
printf '%s' "$BODY" | node $F context.ts ingest --source $SRC --commit $SHA --topic verify-T-07
node $A context.ts search --topic verify-T-07 --json | node -pe 'JSON.parse(require("fs").readFileSync(0)).length + " rows for verify-T-07"'

hr "extra: superseded exclusion (#$D1 replaced by #$D2)"
node $A context.ts search --topic verify-T-02 --json | node -pe 'const r=JSON.parse(require("fs").readFileSync(0)); "ids returned: " + r.map(x=>x.id).join(",") + "; superseded #'$D1' present: " + r.some(x=>x.id==='$D1')'
sql "select id, ref from public.context_log where topic = 'verify-T-02' order by id"

hr "extra: TRUNCATE blocked, even for postgres"
sql "truncate public.context_log"
sql "select count(*) from public.context_log where topic like 'verify-%'"

hr "9. cleanup with the secret key"
curl -s -w ' [HTTP %{http_code}]\n' -X DELETE "$REST/context_log?topic=like.verify-*" -H "apikey: $SK" -H "Authorization: Bearer $SK" -H 'Prefer: return=representation' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const [j,c]=s.split(" [");console.log("deleted "+JSON.parse(j).length+" rows ["+c)})'
for U in $U1 $U2; do curl -s -o /dev/null -w "auth user delete %{http_code}\n" -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$U" -H "apikey: $SK" -H "Authorization: Bearer $SK"; done
VT=$(sql "delete from public.agents where id = 'verify-temp' returning user_id" | node -pe 'JSON.parse(require("fs").readFileSync(0))[0].user_id'); curl -s -o /dev/null -w "verify-temp registry row removed; auth user delete %{http_code}\n" -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$VT" -H "apikey: $SK" -H "Authorization: Bearer $SK"
node provision.ts list
sql "select count(*) as test_rows_left from public.context_log where topic like 'verify-%'"
