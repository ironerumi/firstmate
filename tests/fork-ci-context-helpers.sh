#!/usr/bin/env bash
# Adapt the upstream workflow simulator to the fork's repository/manual-full
# contexts without changing the upstream test host or its expression evaluator.
# Loaded only by that host through lib.sh. Other Ruby invocations pass through.
ruby() {
  local arg
  local -a args=()
  for arg in "$@"; do
    if [ -n "${CONTEXT_RUBY:-}" ] && [ "$arg" = "$CONTEXT_RUBY" ]; then
      arg="$arg
alias upstream_simulated_context simulated_context
def simulated_context(workflow_name, overrides)
  fork_values = {\"repository\" => \"kunchenguid/firstmate\", \"full\" => \"false\"}
  upstream_overrides = overrides.reject do |pair|
    key, value = pair.split(\"=\", 2)
    next false unless fork_values.key?(key)
    fork_values[key] = value.to_s
    true
  end
  upstream_simulated_context(workflow_name, upstream_overrides).merge(
    \"github.repository\" => fork_values.fetch(\"repository\"),
    \"inputs.full\" => fork_values.fetch(\"full\") == \"true\"
  )
end
"
    fi
    args+=("$arg")
  done
  command ruby "${args[@]}"
}
