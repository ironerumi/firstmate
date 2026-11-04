#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M6KMSKS8MC9HDV09S8HDGM7D
D=$(mktemp -d "$ROOT/.gate-procevent.XXXXXX")
export FM_HOME="$D/home" FM_STATE_OVERRIDE="$D/home/state" FM_DATA_OVERRIDE="$D/home/data" FM_CONFIG_OVERRIDE="$D/home/config" FM_PROJECTS_OVERRIDE="$D/home/projects"
export FM_PROCEVENT_CLAIM_ROOT="$D/claims" FM_PROC_ROOT_OVERRIDE="$D/no-proc" TZ=ENG-9
mkdir -p "$FM_STATE_OVERRIDE" "$D/no-proc" "$D/bin"
PIDS=()
cleanup() {
  set +e
  for p in "${PIDS[@]}"; do kill -KILL -- "-$p" 2>/dev/null; done
  "$ROOT/bin/fm-procevent.sh" sweep-home > "$E/manual-cleanup.log" 2>&1
  rm -rf "$D"
}
trap cleanup EXIT
pe() { "$ROOT/bin/fm-procevent.sh" "$@"; }
elapsed() { local t; t=$(<"$E/t0"); printf '\nSCENARIO %s (elapsed minutes=%s)\n' "$1" "$(( ($(date +%s)-t)/60 ))"; }
cat > "$D/blocker" <<'SH'
#!/usr/bin/env bash
printf 'polling\n' > "$1"
exec sleep 180
SH
chmod +x "$D/blocker"
arm() {
  pe register lavish "$1" -- "$D/blocker" "$D/$1.started"
  pe reconcile
  local n=0
  while [ ! -s "$D/$1.started" ]; do n=$((n+1)); [ "$n" -lt 100 ]; sleep .1; done
  CLAIM="$D/claims/$1.claim"
  PID=$(awk 'NR==2 {print; exit}' "$CLAIM")
  PIDS+=("$PID")
}
identity() { COLUMNS=10000 LC_ALL=C ps -p "$1" -o lstart= -o command= | perl -pe 's/^\s+//'; }
set_identity() { awk -v v="$2" 'NR==4 {print v; next} {print}' "$1" > "$1.tmp"; mv "$1.tmp" "$1"; chmod 600 "$1"; }
owner() { pe list | awk -v id="$1" '$1==id {print $3}'; }
wakes() { if [ -e "$FM_STATE_OVERRIDE/.wake-queue" ]; then awk -F '\t' -v id="$1" '$3=="check" && index($4,"procevent:" id ":stranded:")==1 {n++} END {print n+0}' "$FM_STATE_OVERRIDE/.wake-queue"; else echo 0; fi; }
elapsed 'Three pre-update runners stay live, produce no stranded wakes, and can retire'
for id in legacy-one legacy-two legacy-three; do
  arm "$id"
  pinned=$(awk 'NR==4 {print; exit}' "$CLAIM")
  legacy=$(identity "$PID")
  [ "$pinned" != "$legacy" ]
  printf 'source=%s pid=%s\nUTC claim: %s\nLegacy persisted identity: %s\n' "$id" "$PID" "$pinned" "$legacy"
  set_identity "$CLAIM" "$legacy"
done
out=$(pe reconcile); printf '%s\n' "$out"
[[ "$out" == *started=0* && "$out" == *uncertain=0* ]]
pe list
for id in legacy-one legacy-two legacy-three; do
  [ "$(owner "$id")" = live ]; [ "$(wakes "$id")" = 0 ]
  pid=$(awk 'NR==2 {print;exit}' "$D/claims/$id.claim"); kill -0 "$pid"
  printf '%s: live process confirmed, stranded wakes=0\n' "$id"
  pe retire "$id"
  if kill -0 "$pid" 2>/dev/null; then echo 'retire left runner alive'; exit 1; fi
done
printf 'PASS legacy runners\n'
elapsed 'A claim naming a different start time is orphaned, not accepted or relaunched'
arm reused-source
pinned=$(awk 'NR==4 {print;exit}' "$CLAIM"); legacy=$(identity "$PID")
set_identity "$CLAIM" "Mon Jan  1 00:00:00 2001 $(ps -p "$PID" -o command= | perl -pe 's/^\s+//')"
out=$(pe reconcile); printf '%s\n' "$out"; pe list
[[ "$out" == *started=0* && "$out" == *uncertain=1* ]]
[ "$(owner reused-source)" = orphaned ]; [ "$(wakes reused-source)" = 1 ]; kill -0 "$PID"
printf 'stranded wakes=%s; unrelated live PID preserved\n' "$(wakes reused-source)"
printf 'PASS mismatched generation\n'
elapsed 'Unreadable legacy rendering refuses retirement without killing the runner'
set_identity "$CLAIM" "$legacy"
real_ps=$(command -v ps)
printf '#!/usr/bin/env bash\n[ "${TZ:-}" = UTC0 ] || exit 1\nexec "%s" "$@"\n' "$real_ps" > "$D/bin/ps"
chmod +x "$D/bin/ps"
PATH="$D/bin:$PATH" pe list
[ "$(PATH="$D/bin:$PATH" owner reused-source)" = uncertain ]
set +e
out=$(PATH="$D/bin:$PATH" pe retire reused-source 2>&1); rc=$?
set -e
printf 'retire exit=%s\n%s\n' "$rc" "$out"
[ "$rc" -ne 0 ]; [[ "$out" == *'cannot confirm runner identity'* ]]
[ "$(awk 'NR==2 {print;exit}' "$CLAIM")" = "$PID" ]; kill -0 "$PID"
printf 'claim retained; runner remains alive\nPASS unreadable identity (ps boundary fault injection)\n'
set_identity "$CLAIM" "$pinned"; pe retire reused-source
elapsed 'A genuinely dead legacy runner with surviving group is still reported stranded'
arm dead-source
set_identity "$CLAIM" "$(identity "$PID")"
kill -KILL "$PID"
for n in $(seq 1 100); do
  if ! kill -0 "$PID" 2>/dev/null || [ "$(ps -p "$PID" -o stat= | cut -c1)" = Z ]; then break; fi
  sleep .05
done
kill -0 -- "-$PID"
out=$(pe reconcile); printf '%s\n' "$out"; pe list
[[ "$out" == *started=0* && "$out" == *uncertain=1* ]]
[ "$(owner dead-source)" = orphaned ]; [ "$(wakes dead-source)" = 1 ]
printf 'stranded wakes=%s\n' "$(wakes dead-source)"
printf 'PASS dead runner\n'
printf '\nPersisted watcher wakes:\n'
if [ -f "$FM_STATE_OVERRIDE/.wake-queue" ]; then perl -pe '' "$FM_STATE_OVERRIDE/.wake-queue"; fi
printf '\nALL LIVE CLI SCENARIOS PASSED\n'
