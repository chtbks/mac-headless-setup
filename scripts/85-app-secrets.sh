#!/usr/bin/env bash
# 85-app-secrets.sh — make the Chatbooks build-time secrets available on the box.
#
# The Chatbooks iOS repo injects secrets at build time from
# Secrets/Secrets.xcconfig, whose keys are ALSO the CI environment-variable
# names (see Secrets/README.md + ci_scripts/ci_post_clone.sh). On this build
# host we resolve those values once and persist them as environment exports in
# ~/.chatbooks-build.env, sourced from the login shell — so any checkout can
# generate its Secrets.xcconfig from the environment, exactly like CI does.
#
# Currently the only required key is GOOGLE_PLACES_API_KEY. Add more here (and
# to config.example.env) as the template grows.
#
# Sourced by setup.sh; defines module_main.

# Keys the Chatbooks build expects in the environment. Keep in sync with
# iphone/Secrets/Secrets.xcconfig.template.
APP_SECRET_KEYS=(GOOGLE_PLACES_API_KEY)

module_main() {
  local build_env="${HOME}/.chatbooks-build.env"
  local tmp="${build_env}.tmp.$$"
  : >"${tmp}"
  chmod 600 "${tmp}"

  local key val resolved=0 missing=()
  for key in "${APP_SECRET_KEYS[@]}"; do
    # LastPass entry name derives from the key: MacSetup/google-places-api-key
    local lp_entry="MacSetup/$(printf '%s' "${key}" | tr 'A-Z_' 'a-z-')"
    val="$(get_secret "${key}" "${lp_entry}" "${key} (Chatbooks build secret)" --optional)"
    if [[ -n "${val}" ]]; then
      printf 'export %s=%q\n' "${key}" "${val}" >>"${tmp}"
      resolved=$((resolved+1))
    else
      missing+=("${key}")
    fi
  done

  if (( resolved == 0 )); then
    rm -f "${tmp}"
    log_warn "no Chatbooks build secrets provided"
    add_manual_todo "Provide Chatbooks build secrets (${APP_SECRET_KEYS[*]}) via LastPass/config.env, then: ./setup.sh --only 85-app-secrets"
    return 0
  fi

  mv "${tmp}" "${build_env}"
  chmod 600 "${build_env}"
  log_ok "wrote ${resolved} build secret(s) to ${build_env} (mode 600)"

  # Ensure the login shell sources it (idempotent).
  local zprofile="${HOME}/.zprofile"
  local src_line='[ -f "$HOME/.chatbooks-build.env" ] && source "$HOME/.chatbooks-build.env"'
  if ! grep -qsF "${src_line}" "${zprofile}" 2>/dev/null; then
    printf '\n# Chatbooks build secrets (added by MacSetup)\n%s\n' "${src_line}" >>"${zprofile}"
    log_info "added source line to ${zprofile}"
  fi

  if ((${#missing[@]})); then
    log_warn "still missing: ${missing[*]}"
    add_manual_todo "Provide remaining Chatbooks build secrets: ${missing[*]}"
  fi
  return 0
}
