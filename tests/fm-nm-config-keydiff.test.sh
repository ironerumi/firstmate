#!/usr/bin/env bash
# Tests for fm-nm-config-keydiff.sh, the no-mistakes default-config keydiff
# report.
#
# The check exists because a no-mistakes upgrade ships new default settings and
# a long-lived operator config that predates them keeps running without them:
# nothing tells the operator the config silently missed settings the new build
# now expects. test_missing_default_keys_are_reported pins the extraction: the
# fake binary's strings output carries the same shape the real build embeds -
# junk before the template marker, the marker, a contiguous template, then
# unrelated embedded strings past a block-closing line - and the report must
# name exactly the template keys the operator config lacks, never the junk or
# the strings past the block.
#
# The fixtures never touch a no-mistakes actually installed on this host: the
# fake binary is an executable text file whose strings output is the fixture,
# and the operator config is a temp file under FM_NM_CONFIG. The one check run
# that must be silent when no binary resolves forces PATH to /usr/bin:/bin and
# HOME to an empty temp dir so neither the real host binary nor any standard
# location can answer for it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-nm-config-keydiff.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-config-keydiff)

# The six default keys ironerumi/firstmate issue #31 flagged, all present in the
# fixture template: an operator config carrying only the older keys lacks every
# one of them, and the report must name them all.
EXPECTED_ALL_MISSING='agent_timeout, branch_sync_remote_timeout, eval, forgejo_axi_path, review_agent_timeout, test_agent_timeout'

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The fake no-mistakes binary: an executable text file whose strings output
# carries the embedded-template shape the real build embeds. Nothing ever
# executes it; the probe is `strings` only.
make_binary() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/no-mistakes" <<'NM'
#!/usr/bin/env bash
# junk before the template marker must never be parsed
bogus: junk
exit 0
# no-mistakes global configuration
agent: auto
# forgejo-axi executable used for Forgejo provider operations
forgejo_axi_path: forgejo-axi
ci_timeout: "168h"
step_quiet_warning: "10m"
agent_timeout: "30m"
review_agent_timeout: "30m"
test_agent_timeout: "30m"
daemon_connect_timeout: "3s"
branch_sync_remote_timeout: "60s"
session_reuse: true
log_level: info
auto_fix:
  rebase: 3
intent:
  enabled: true
eval:
  capture_provenance: true
  max_cases: 200
# The shell completions begin here and must close the template block; embedded
# strings past this point must not leak into the key set.
function __nm_completion {
# json:"id"
json:"id"
yaml:"ci"
file: x
NM
  chmod 0755 "$dir/no-mistakes"
}

# An operator config with only the long-lived keys, missing every #31 key.
cat > "$TMP_ROOT/config-missing.yaml" <<'YAML'
agent: [codex, pi]
ci_timeout: "168h"
step_quiet_warning: "10m"
daemon_connect_timeout: "3s"
session_reuse: true
log_level: info
auto_fix:
  rebase: 3
intent:
  enabled: true
YAML

# One that sets every default key the fixture template ships.
cat > "$TMP_ROOT/config-complete.yaml" <<'YAML'
agent: [codex, pi]
forgejo_axi_path: forgejo-axi
ci_timeout: "168h"
step_quiet_warning: "10m"
agent_timeout: "30m"
review_agent_timeout: "30m"
test_agent_timeout: "30m"
daemon_connect_timeout: "3s"
branch_sync_remote_timeout: "60s"
session_reuse: true
log_level: info
auto_fix:
  rebase: 3
intent:
  enabled: true
eval:
  capture_provenance: true
  max_cases: 200
YAML

# The fixture directory first, then the ambient PATH, which the check needs
# because it shells out to ordinary tools such as strings, grep, awk, sed, and
# stat. What keeps a real tool installed on this host out of a fixture is that
# the fixture direction always answers first, not this PATH.
fixture_path() {
  printf '%s:%s\n' "$1" "$PATH"
}

run_check() {
  local home=$1 path=$2 config=$3 out=$4
  shift 4
  local status=0
  env "$@" FM_CHECK_TIMEOUT=30 FM_HOME="$home" PATH="$path" FM_NM_CONFIG="$config" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# --- the report itself -------------------------------------------------------

test_missing_default_keys_are_reported() {
  local home bin_dir out report key
  home=$(make_home report)
  bin_dir="$TMP_ROOT/report/bin"
  make_binary "$bin_dir"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$bin_dir")" "$TMP_ROOT/config-missing.yaml" "$out"
  report=$(cat "$out")
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must be exactly one line for the wake record"
  assert_contains "$report" "no-mistakes config" "the report is missing its one-line prefix"
  assert_contains "$report" "is missing default keys:" "the report does not say keys are missing"
  for key in agent_timeout review_agent_timeout test_agent_timeout \
    branch_sync_remote_timeout forgejo_axi_path eval; do
    assert_contains "$report" "$key" "missing default key $key was not reported"
  done
  pass "the config keydiff reports every missing default key on one line"
}

test_embedded_strings_outside_the_template_block_are_not_keys() {
  local home bin_dir out report
  home=$(make_home bound)
  bin_dir="$TMP_ROOT/bound/bin"
  make_binary "$bin_dir"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$bin_dir")" "$TMP_ROOT/config-missing.yaml" "$out"
  report=$(cat "$out")
  # The junk before the marker, and the key-shaped embedded strings after the
  # shell-completion line, must never read as template defaults: the block
  # starts at the marker and ends at the first non-template line, never at a
  # line number.
  assert_not_contains "$report" "bogus:" "junk before the template marker was parsed as a default key"
  assert_not_contains "$report" "json:" "an embedded string past the template block was parsed as a default key"
  assert_not_contains "$report" "yaml:" "an embedded string past the template block was parsed as a default key"
  assert_not_contains "$report" "file: x" "an embedded string past the template block was parsed as a default key"
  pass "the template block bound is the marker and content shape, with unrelated embedded strings excluded"
}

test_config_with_every_default_key_is_silent() {
  local home bin_dir out
  home=$(make_home complete)
  bin_dir="$TMP_ROOT/complete/bin"
  make_binary "$bin_dir"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$bin_dir")" "$TMP_ROOT/config-complete.yaml" "$out"
  [ ! -s "$out" ] || fail "a config carrying every default key reported: $(cat "$out")"
  pass "a complete config produces no report at all"
}

test_absent_config_is_silent() {
  local home bin_dir out
  home=$(make_home no-config)
  bin_dir="$TMP_ROOT/no-config/bin"
  make_binary "$bin_dir"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$bin_dir")" "$TMP_ROOT/does-not-exist.yaml" "$out"
  [ ! -s "$out" ] || fail "an absent config produced a report: $(cat "$out")"
  assert_absent "$home/state/.nm-config-keydiff" "an absent config wrote a report record"
  pass "no config file means no report and no record"
}

test_unreadable_config_is_silent() {
  local home bin_dir config out
  home=$(make_home unreadable-config)
  bin_dir="$TMP_ROOT/unreadable-config/bin"
  make_binary "$bin_dir"
  config="$TMP_ROOT/unreadable-config/config.yaml"
  cp "$TMP_ROOT/config-missing.yaml" "$config"
  chmod 000 "$config"
  out="$home/out.txt"

  run_check "$home" "$(fixture_path "$bin_dir")" "$config" "$out"
  chmod 0600 "$config"
  [ ! -s "$out" ] || fail "an unreadable config produced output: $(cat "$out")"
  assert_absent "$home/state/.nm-config-keydiff" "an unreadable config wrote a fabricated report record"
  pass "a config read failure is silent and records no fabricated finding"
}

test_absent_binary_is_silent() {
  local home out
  home=$(make_home no-binary)
  out="$home/out.txt"
  # /usr/bin and /bin hold the shell tools the script needs but no no-mistakes;
  # HOME is pointed at an empty temp dir so the standard no-mistakes install
  # location cannot answer for the real host binary either.
  run_check "$home" "/usr/bin:/bin" "$TMP_ROOT/config-missing.yaml" "$out" HOME="$TMP_ROOT/no-binary/home"
  [ ! -s "$out" ] || fail "a missing binary produced a report: $(cat "$out")"
  assert_absent "$home/state/.nm-config-keydiff" "a run that could not read the binary wrote a report record"
  pass "no resolvable no-mistakes binary means no report and no record"
}

test_real_binary_is_found_after_a_guard_shim() {
  local home shim_dir empty_dir bin_dir out path
  home=$(make_home path-walk)
  shim_dir="$TMP_ROOT/path-walk/shims"
  empty_dir="$TMP_ROOT/path-walk/empty"
  bin_dir="$TMP_ROOT/path-walk/bin"
  mkdir -p "$shim_dir" "$empty_dir"
  ln -s "$ROOT/bin/fm-nm-guard-shim.sh" "$shim_dir/no-mistakes"
  make_binary "$bin_dir"
  out="$home/out.txt"
  path="$shim_dir:$empty_dir:$bin_dir:/usr/bin:/bin"

  run_check "$home" "$path" "$TMP_ROOT/config-missing.yaml" "$out" HOME="$TMP_ROOT/path-walk/home"
  assert_contains "$(cat "$out")" "agent_timeout" "the real binary in a middle PATH entry was not found after the guard shim"
  pass "the real binary is found in a middle PATH entry after a guard shim"
}

test_findings_are_reported_once_until_they_change() {
  local home bin_dir config out
  home=$(make_home no-nag)
  bin_dir="$TMP_ROOT/no-nag/bin"
  make_binary "$bin_dir"
  config="$TMP_ROOT/no-nag/config.yaml"
  cp "$TMP_ROOT/config-missing.yaml" "$config"
  out="$home/out.txt"
  path=$(fixture_path "$bin_dir")

  run_check "$home" "$path" "$config" "$out"
  assert_contains "$(cat "$out")" "agent_timeout" "the first run did not report the missing keys"
  run_check "$home" "$path" "$config" "$out"
  [ ! -s "$out" ] || fail "the same missing-key finding was reported twice: $(cat "$out")"

  # A changed finding is news again: adopting one key shrinks the set.
  printf 'eval:\n  capture_provenance: true\n' >> "$config"
  run_check "$home" "$path" "$config" "$out"
  assert_contains "$(cat "$out")" "agent_timeout" "the smaller finding set was suppressed as a repeat"
  assert_not_contains "$(cat "$out")" "eval," "an adopted key stayed in the changed finding set"
  run_check "$home" "$path" "$config" "$out"
  [ ! -s "$out" ] || fail "the changed finding was reported twice: $(cat "$out")"

  # Once the condition clears, the report clears with it, and a later return of
  # the same condition is reported again.
  cp "$TMP_ROOT/config-complete.yaml" "$config"
  run_check "$home" "$path" "$config" "$out"
  [ ! -s "$out" ] || fail "a cleared finding still produced a report: $(cat "$out")"
  rm -f -- "$config"
  cp "$TMP_ROOT/config-missing.yaml" "$config"
  run_check "$home" "$path" "$config" "$out"
  assert_contains "$(cat "$out")" "agent_timeout" "a returning finding was not reported again"
  pass "the same finding is reported once, and a change or return is reported again"
}

test_unreadable_probe_clears_the_report_record() {
  local home bin_dir hidden config out path
  home=$(make_home unreadable-recovery)
  bin_dir="$TMP_ROOT/unreadable-recovery/bin"
  hidden="$TMP_ROOT/unreadable-recovery/no-mistakes.hidden"
  config="$TMP_ROOT/config-missing.yaml"
  make_binary "$bin_dir"
  out="$home/out.txt"
  path="$bin_dir:/usr/bin:/bin"

  run_check "$home" "$path" "$config" "$out" HOME="$TMP_ROOT/unreadable-recovery/home"
  assert_contains "$(cat "$out")" "agent_timeout" "the initial finding was not reported"
  assert_present "$home/state/.nm-config-keydiff" "the initial finding did not write its report record"

  mv "$bin_dir/no-mistakes" "$hidden"
  run_check "$home" "$path" "$config" "$out" HOME="$TMP_ROOT/unreadable-recovery/home"
  [ ! -s "$out" ] || fail "an unreadable probe produced a report: $(cat "$out")"
  assert_absent "$home/state/.nm-config-keydiff" "an unreadable probe retained the prior report record"

  mv "$hidden" "$bin_dir/no-mistakes"
  run_check "$home" "$path" "$config" "$out" HOME="$TMP_ROOT/unreadable-recovery/home"
  assert_contains "$(cat "$out")" "agent_timeout" "the restored readable probe did not report the unchanged finding again"
  pass "an unreadable probe clears dedupe so restored findings report again"
}

test_the_report_record_carries_the_full_finding_set() {
  local home bin_dir out
  home=$(make_home record)
  bin_dir="$TMP_ROOT/record/bin"
  make_binary "$bin_dir"
  out="$home/out.txt"
  run_check "$home" "$(fixture_path "$bin_dir")" "$TMP_ROOT/config-missing.yaml" "$out"
  assert_contains "$(cat "$home/state/.nm-config-keydiff")" "fm-nm-config-keydiff-v1" "the record has the wrong schema"
  assert_contains "$(cat "$home/state/.nm-config-keydiff")" "reported=$EXPECTED_ALL_MISSING" "the record does not carry the whole finding set the report was made from"
  pass "the report record names the schema and the whole finding set"
}

# --- the config is never written ---------------------------------------------

test_no_subcommand_writes_the_operator_config() {
  local home bin_dir config before after
  home=$(make_home fingerprint)
  bin_dir="$TMP_ROOT/fingerprint/bin"
  make_binary "$bin_dir"
  config="$TMP_ROOT/fingerprint/config.yaml"
  cp "$TMP_ROOT/config-missing.yaml" "$config"
  before=$(shasum -a 256 "$config" | awk '{print $1}')

  run_check "$home" "$(fixture_path "$bin_dir")" "$config" "$home/out1.txt"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$config" "$CHECK" arm >/dev/null 2>&1 || fail "arm failed"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$config" "$CHECK" check >/dev/null 2>&1 || fail "check failed"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$config" "$CHECK" disarm >/dev/null 2>&1 || fail "disarm failed"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$config" "$CHECK" --help >/dev/null 2>&1 || fail "--help failed"

  after=$(shasum -a 256 "$config" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a subcommand changed the operator config"
  pass "check, arm, disarm, and --help never write the operator config"
}

# --- arm and disarm ----------------------------------------------------------

test_arm_registers_the_check_and_disarm_removes_it() {
  local home bin_dir status
  home=$(make_home arm)
  bin_dir="$TMP_ROOT/arm/bin"
  make_binary "$bin_dir"

  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/nm-config-keydiff.check.sh" "arm did not write the check shim"
  assert_present "$home/state/nm-config-keydiff.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/nm-config-keydiff.check.sh" 2>/dev/null || stat -f %Lp "$home/state/nm-config-keydiff.check.sh")" = 700 ] \
    || fail "the check shim is not mode 700"
  assert_grep 'fm-custom-check-v1' "$home/state/nm-config-keydiff.check-trust" "the trust binding has the wrong schema"

  # Arming twice must stay valid rather than invalidating its own binding.
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/nm-config-keydiff.check-trust" "re-arming lost the trust binding"

  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/nm-config-keydiff.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.nm-config-keydiff" "disarm left the report record behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_arm_refuses_without_config_or_template() {
  local home bin_dir status
  home=$(make_home arm-refuse)

  status=0
  env FM_HOME="$home" FM_NM_CONFIG="$TMP_ROOT/does-not-exist.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm without an operator config exit"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "arm armed a check with no config to diff"

  bin_dir="$TMP_ROOT/arm-refuse/bin"
  make_binary "$bin_dir"
  status=0
  env FM_HOME="$home" PATH="/usr/bin:/bin" HOME="$TMP_ROOT/arm-refuse/home" \
    FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm without a resolvable binary exit"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "arm armed a check whose default keys can never be read"
  pass "arm fails loudly when the config or the binary's template is unreadable"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home bin_dir target mode status
  home=$(make_home arm-symlink)
  bin_dir="$TMP_ROOT/arm-symlink/bin"
  make_binary "$bin_dir"
  target="$TMP_ROOT/arm-symlink/not-the-shim.txt"
  printf 'a file the shim must not touch\n' > "$target"
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  ln -s "$target" "$home/state/nm-config-keydiff.check.sh"

  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink exit"
  [ "$(cat "$target")" = 'a file the shim must not touch' ] || fail "arm followed the symlink and overwrote its target"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ] || fail "arm changed the mode of the symlink's target"
  assert_absent "$home/state/nm-config-keydiff.check-trust" "arm registered a shim it refused to write"
  pass "a symlink at the shim path is refused instead of followed"
}

test_a_failed_registration_leaves_no_unregistered_shim() {
  local home bin_dir target stale_shim status
  home=$(make_home arm-register-fail)
  bin_dir="$TMP_ROOT/arm-register-fail/bin"
  make_binary "$bin_dir"
  # A symlink at the trust path makes registration refuse, the shape any
  # register failure has from arm's side.
  target="$TMP_ROOT/arm-register-fail/not-the-trust.txt"
  printf 'a file the trust binding must not touch\n' > "$target"
  ln -s "$target" "$home/state/nm-config-keydiff.check-trust"

  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an unusable trust path exit"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "a failed registration left an unregistered check shim behind"
  [ "$(cat "$target")" = 'a file the trust binding must not touch' ] || fail "arm wrote through the trust symlink"

  # A shim that was already there is only kept when its trust binding is still
  # intact. Here the binding is unusable, so putting the old bytes back would
  # leave exactly the unbound shim the watcher wakes about, and the home has to
  # end plainly not armed instead.
  stale_shim="$TMP_ROOT/arm-register-fail/shim-armed-earlier"
  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' > "$stale_shim"
  cp "$stale_shim" "$home/state/nm-config-keydiff.check.sh"
  chmod 0700 "$home/state/nm-config-keydiff.check.sh"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over an existing shim with an unusable trust path exit"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "a failed arm left a shim behind that no trust binding covers"
  pass "a failed registration never leaves a shim without a matching trust binding"
}

test_a_failed_rearm_leaves_no_shim_the_trust_binding_lost() {
  local home bin_dir fake hash_calls status
  home=$(make_home arm-rearm-fail)
  bin_dir="$TMP_ROOT/arm-rearm-fail/bin"
  make_binary "$bin_dir"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null || fail "the first arm failed"
  assert_present "$home/state/nm-config-keydiff.check-trust" "the first arm did not bind the shim"

  # Make registration replace the old binding with a syntactically valid hash,
  # then fail while verifying it. This deterministically reaches the rollback
  # state where registration removed the trust binding; a hash command that
  # fails immediately can leave the old binding intact under pipefail.
  fake="$TMP_ROOT/arm-rearm-fail/fake-hash"
  hash_calls="$TMP_ROOT/arm-rearm-fail/hash-calls"
  mkdir -p "$fake"
  cat > "$fake/shasum" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$hash_calls' ] || count=\$(cat '$hash_calls')
count=\$((count + 1))
printf '%s\n' "\$count" > '$hash_calls'
if [ "\$count" -eq 1 ]; then
  printf '%064d  %s\n' 0 "\${3:-}"
  exit 0
fi
exit 1
EOF
  cp "$fake/shasum" "$fake/sha256sum"
  chmod 0755 "$fake/shasum" "$fake/sha256sum"
  printf '#!/usr/bin/env bash\n# a shim armed earlier\nexit 0\n' > "$home/state/nm-config-keydiff.check.sh"
  chmod 0700 "$home/state/nm-config-keydiff.check.sh"

  status=0
  env FM_HOME="$home" PATH="$fake:$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm whose registration cannot hash exit"
  assert_absent "$home/state/nm-config-keydiff.check.sh" "a failed re-arm left a shim behind after the trust binding was removed"
  assert_absent "$home/state/nm-config-keydiff.check-trust" "the failed registration left a trust binding behind"
  pass "a re-arm that loses the trust binding leaves no shim behind"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home bin_dir out status
  home=$(make_home arm-relative)
  bin_dir="$TMP_ROOT/arm-relative/bin"
  make_binary "$bin_dir"

  status=0
  (cd "$TMP_ROOT" && env PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    FM_HOME=arm-relative "$CHECK" arm >/dev/null 2>&1) || status=$?
  expect_code 0 "$status" "arm with a relative home exit"

  out="$home/out.txt"
  status=0
  (cd / && env -u FM_HOME PATH="$(fixture_path "$bin_dir")" FM_CHECK_TIMEOUT=30 \
    FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$home/state/nm-config-keydiff.check.sh" >"$out" 2>&1) || status=$?
  expect_code 0 "$status" "shim run from another directory exit"
  assert_contains "$(cat "$out")" "agent_timeout" "the shim read a different home than the one it was armed for"
  pass "a relative home is resolved before it is persisted into the shim"
}

test_armed_check_wakes_the_watcher_with_the_report() {
  local home bin_dir out err status
  home=$(make_home wake)
  bin_dir="$TMP_ROOT/wake/bin"
  make_binary "$bin_dir"
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    "$CHECK" arm >/dev/null || fail "could not arm the config keydiff check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" PATH="$(fixture_path "$bin_dir")" FM_CHECK_TIMEOUT=30 \
    FM_NM_CONFIG="$TMP_ROOT/config-missing.yaml" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "no-mistakes config" "the wake did not carry the config keydiff report"
  assert_contains "$(cat "$out")" "agent_timeout" "the wake did not name a missing default key"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

# --- usage -------------------------------------------------------------------

test_help_and_invalid_actions() {
  local out status
  out="$TMP_ROOT/help.txt"
  "$CHECK" --help >"$out" 2>&1 || fail "--help failed"
  assert_contains "$(cat "$out")" "check" "--help does not document check"
  assert_contains "$(cat "$out")" "arm" "--help does not document arm"
  assert_contains "$(cat "$out")" "disarm" "--help does not document disarm"

  status=0
  "$CHECK" bogus-action >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown action exit"
  pass "--help documents the actions and an unknown action refuses"
}

test_missing_default_keys_are_reported
test_embedded_strings_outside_the_template_block_are_not_keys
test_config_with_every_default_key_is_silent
test_absent_config_is_silent
test_unreadable_config_is_silent
test_absent_binary_is_silent
test_real_binary_is_found_after_a_guard_shim
test_findings_are_reported_once_until_they_change
test_unreadable_probe_clears_the_report_record
test_the_report_record_carries_the_full_finding_set
test_no_subcommand_writes_the_operator_config
test_arm_registers_the_check_and_disarm_removes_it
test_arm_refuses_without_config_or_template
test_arm_refuses_a_symlink_at_the_shim_path
test_a_failed_registration_leaves_no_unregistered_shim
test_a_failed_rearm_leaves_no_shim_the_trust_binding_lost
test_arm_resolves_a_relative_home_into_the_shim
test_armed_check_wakes_the_watcher_with_the_report
test_help_and_invalid_actions
