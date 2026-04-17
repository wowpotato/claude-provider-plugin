#!/bin/bash
# One-click setup for claude-provider multi-plan switching
#
# What this script does (idempotent — safe to re-run):
#   1. Check prerequisites (macOS, jq, node v18+, git, claude CLI)
#   2. Clone/update the fork and install the plugin globally
#   3. Write swap-credentials.sh and refresh-credentials.sh into ~/.claude/
#   4. Merge SessionStart + PostToolUse hooks into ~/.claude/settings.json
#   5. Create settings.anthropic-team.json if missing
#   6. Optionally walk the user through credential capture
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wowpotato/claude-provider-plugin/wowpotato-main/scripts/setup.sh | bash
# or:
#   bash scripts/setup.sh

set -euo pipefail

REPO_URL="https://github.com/wowpotato/claude-provider-plugin.git"
REPO_BRANCH="wowpotato-main"
CLONE_DIR="$HOME/Documents/GitHub/claude-provider-plugin"
CLAUDE_DIR="$HOME/.claude"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}==>${RESET} $*"; }
ok()     { echo -e "${GREEN}✔${RESET} $*"; }
warn()   { echo -e "${YELLOW}⚠${RESET} $*"; }
err()    { echo -e "${RED}✗${RESET} $*" >&2; }
header() { echo; echo -e "${BOLD}${CYAN}── $* ──${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: prerequisites
# ─────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
  header "1/6  prerequisites"

  [[ "$(uname)" == "Darwin" ]] || { err "macOS only (current: $(uname))"; exit 1; }
  ok "macOS detected"

  for cmd in git node npm jq curl claude security; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "missing command: $cmd"
      case "$cmd" in
        jq|node) echo "   install: brew install $cmd" ;;
        claude)  echo "   install Claude Code first: https://docs.anthropic.com/en/docs/claude-code" ;;
      esac
      exit 1
    fi
  done
  ok "git, node, npm, jq, curl, claude, security all present"

  local node_major
  node_major=$(node -v | sed 's/^v\([0-9]*\).*/\1/')
  if [[ "$node_major" -lt 18 ]]; then
    err "Node.js v18+ required (current: $(node -v))"
    exit 1
  fi
  ok "Node.js $(node -v)"

  if ! claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null; then
    err "claude CLI is not logged in. Run 'claude auth login' first."
    exit 1
  fi
  ok "claude CLI logged in as $(claude auth status | jq -r .email)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: install plugin from fork
# ─────────────────────────────────────────────────────────────────────────────
install_plugin() {
  header "2/6  install forked claude-provider plugin"

  mkdir -p "$(dirname "$CLONE_DIR")"
  if [[ -d "$CLONE_DIR/.git" ]]; then
    log "existing clone found — updating"
    git -C "$CLONE_DIR" fetch origin "$REPO_BRANCH" >/dev/null 2>&1
    git -C "$CLONE_DIR" checkout "$REPO_BRANCH" >/dev/null 2>&1
    git -C "$CLONE_DIR" pull --ff-only origin "$REPO_BRANCH" >/dev/null 2>&1
  else
    log "cloning $REPO_URL ($REPO_BRANCH)"
    git clone -b "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR" >/dev/null 2>&1
  fi
  ok "fork ready at $CLONE_DIR"

  # clean broken symlink from prior failed installs
  if [[ -L /opt/homebrew/lib/node_modules/claude-provider && ! -d /opt/homebrew/lib/node_modules/claude-provider ]]; then
    warn "removing broken symlink at /opt/homebrew/lib/node_modules/claude-provider"
    rm -f /opt/homebrew/lib/node_modules/claude-provider
  fi

  log "npm install -g ."
  (cd "$CLONE_DIR" && npm install -g . >/dev/null)

  local installed_version
  installed_version=$(cpr --version 2>&1 || echo "unknown")
  ok "cpr installed: $installed_version  ($(which cpr))"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: helper scripts
# ─────────────────────────────────────────────────────────────────────────────
write_swap_script() {
  cat > "$CLAUDE_DIR/swap-credentials.sh" <<'SCRIPT'
#!/bin/bash
# Claude Code credential swap script (installed by setup.sh)
set -euo pipefail

KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="$(whoami)"
CRED_DIR="$HOME/.claude"

usage() {
  echo "Usage: $0 {save|restore|auto-swap|list} [profile]"
  exit 1
}

save_credential() {
  local profile="$1"
  local cred_file="$CRED_DIR/credentials.${profile}.json"
  local token
  token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null) || {
    echo "ERROR: No credential found in keychain" >&2; exit 1
  }
  echo "$token" > "$cred_file"
  chmod 600 "$cred_file"
  echo "Saved credential for profile '$profile' -> $cred_file"
}

restore_credential() {
  local profile="$1"
  local cred_file="$CRED_DIR/credentials.${profile}.json"
  [[ -f "$cred_file" ]] || { echo "SKIP: No credential file for '$profile'" >&2; return 0; }
  local token
  token=$(cat "$cred_file")
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$token" 2>/dev/null || {
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null || true
    security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$token"
  }
  echo "Restored credential for profile '$profile' from $cred_file"
}

auto_swap() {
  local input; input=$(cat)
  local profile; profile=$(echo "$input" | jq -r '.tool_input.profile // empty' 2>/dev/null) || true
  [[ -z "$profile" ]] && return 0
  local current; current=$(cat "$CRED_DIR/.active-profile" 2>/dev/null || echo "")
  if [[ -n "$current" && "$current" != "$profile" ]]; then
    save_credential "$current" 2>/dev/null || true
  fi
  restore_credential "$profile"
  echo "$profile" > "$CRED_DIR/.active-profile"
}

list_credentials() {
  for f in "$CRED_DIR"/credentials.*.json; do
    [[ -f "$f" ]] || continue
    basename "$f" | sed 's/^credentials\.//; s/\.json$//'
  done
  echo "Active: $(cat "$CRED_DIR/.active-profile" 2>/dev/null || echo "(unknown)")"
}

[[ $# -lt 1 ]] && usage
case "$1" in
  save)    [[ $# -lt 2 ]] && usage; save_credential "$2" ;;
  restore) [[ $# -lt 2 ]] && usage; restore_credential "$2" ;;
  auto-swap) auto_swap ;;
  list)    list_credentials ;;
  *)       usage ;;
esac
SCRIPT
  chmod +x "$CLAUDE_DIR/swap-credentials.sh"
}

write_refresh_script() {
  cat > "$CLAUDE_DIR/refresh-credentials.sh" <<'SCRIPT'
#!/bin/bash
# Claude Code credential refresh via OAuth refresh token (installed by setup.sh)
set -euo pipefail

CRED_DIR="$HOME/.claude"
OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_URL="https://api.anthropic.com/v1/oauth/token"
CYAN='\033[36m'; GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; DIM='\033[2m'; RESET='\033[0m'

check_credential() {
  local profile="$1"
  local cred_file="$CRED_DIR/credentials.${profile}.json"
  [ -f "$cred_file" ] || { echo -e "  ${DIM}$profile${RESET}: ${YELLOW}no file${RESET}"; return 1; }
  local token; token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)
  [ -z "$token" ] && { echo -e "  ${DIM}$profile${RESET}: ${RED}no token${RESET}"; return 1; }
  local http_code; http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
  if [ "$http_code" = "200" ]; then
    echo -e "  ${DIM}$profile${RESET}: ${GREEN}OK${RESET}"; return 0
  fi
  echo -e "  ${DIM}$profile${RESET}: ${RED}expired (HTTP $http_code)${RESET}"
  return 1
}

check_all() {
  echo -e "${CYAN}=== Credential status ===${RESET}"
  local has_expired=false
  for cred in "$CRED_DIR"/credentials.*.json; do
    [ -f "$cred" ] || continue
    local p; p=$(basename "$cred" | sed 's/^credentials\.//; s/\.json$//')
    check_credential "$p" || has_expired=true
  done
  [ "$has_expired" = "true" ] && echo -e "\n${YELLOW}Some expired. Run: $0 refresh-all${RESET}" || echo -e "\n${GREEN}All good${RESET}"
}

auto_refresh_credential() {
  local profile="$1"
  local cred_file="$CRED_DIR/credentials.${profile}.json"
  [ -f "$cred_file" ] || return 1
  local rt; rt=$(jq -r '.claudeAiOauth.refreshToken // empty' "$cred_file" 2>/dev/null)
  [ -z "$rt" ] && return 1

  local resp; resp=$(curl -s --max-time 10 "$OAUTH_TOKEN_URL" -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token&refresh_token=$rt&client_id=$OAUTH_CLIENT_ID" 2>/dev/null)
  local new_at new_rt exp_in org
  new_at=$(echo "$resp" | jq -r '.access_token // empty')
  new_rt=$(echo "$resp" | jq -r '.refresh_token // empty')
  exp_in=$(echo "$resp" | jq -r '.expires_in // empty')
  org=$(echo "$resp" | jq -r '.organization.name // empty')
  [ -z "$new_at" ] && { echo -e "  ${DIM}$profile${RESET}: ${RED}refresh failed${RESET}"; return 1; }

  local exp_at=$(( $(date +%s) * 1000 + exp_in * 1000 ))
  # IMPORTANT: jq -c is required. Pretty-printed JSON gets stored as
  # binary in the keychain and Claude Code refuses to parse it.
  jq -c --arg at "$new_at" --arg rt "$new_rt" --argjson ea "$exp_at" \
    '.claudeAiOauth.accessToken=$at | .claudeAiOauth.refreshToken=$rt | .claudeAiOauth.expiresAt=$ea' \
    "$cred_file" > "$cred_file.tmp" && mv "$cred_file.tmp" "$cred_file"
  chmod 600 "$cred_file"
  echo -e "  ${DIM}$profile${RESET}: ${GREEN}refreshed${RESET} (${org:-unknown})"
}

refresh_all() {
  local active; active=$(cat "$CRED_DIR/.active-profile" 2>/dev/null || echo "")
  echo -e "${CYAN}=== Auto-refresh inactive profiles ===${RESET}"
  [ -n "$active" ] && echo -e "  ${DIM}skipping active '$active' (token-rotation-safe)${RESET}"
  for cred in "$CRED_DIR"/credentials.*.json; do
    [ -f "$cred" ] || continue
    local p; p=$(basename "$cred" | sed 's/^credentials\.//; s/\.json$//')
    [ "$p" = "$active" ] && continue
    auto_refresh_credential "$p" || true
  done
  rm -rf /tmp/claude-usage/*.json 2>/dev/null || true
}

case "${1:-}" in
  check) check_all ;;
  refresh-all) refresh_all ;;
  *) echo "Usage: $0 {check|refresh-all}"; exit 1 ;;
esac
SCRIPT
  chmod +x "$CLAUDE_DIR/refresh-credentials.sh"
}

install_helper_scripts() {
  header "3/6  helper scripts"

  mkdir -p "$CLAUDE_DIR"
  write_swap_script && ok "$CLAUDE_DIR/swap-credentials.sh"
  write_refresh_script && ok "$CLAUDE_DIR/refresh-credentials.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: merge hooks into settings.json
# ─────────────────────────────────────────────────────────────────────────────
configure_hooks() {
  header "4/6  merge hooks into settings.json"

  local settings="$CLAUDE_DIR/settings.json"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  local session_cmd='bash -c '\''SUB=$(claude auth status 2>/dev/null | jq -r .subscriptionType); if [ "$SUB" = "enterprise" ]; then P=anthropic; elif [ "$SUB" = "team" ]; then P=anthropic-team; else P=""; fi; if [ -n "$P" ]; then echo "$P" > ~/.claude/.active-profile; ~/.claude/swap-credentials.sh save "$P" 2>/dev/null; fi; rm -rf /tmp/claude-usage/*.json 2>/dev/null; ls -t ~/.claude/settings.backup.*.json 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null; true'\'''

  # Non-destructively merge hooks. For each event, drop any existing entry
  # with the same matcher we're about to add, then append ours. Anything
  # else the user has in the file is preserved.
  jq \
    --arg session_cmd "$session_cmd" \
    '
    .hooks = (.hooks // {}) |
    .hooks.SessionStart =
      (((.hooks.SessionStart // []) | map(select((.matcher // "") != ""))) +
       [{matcher: "", hooks: [{type: "command", command: $session_cmd}]}]) |
    .hooks.PostToolUse =
      (((.hooks.PostToolUse // []) | map(select((.matcher // "") != "mcp__plugin_provider_provider__switch_profile"))) +
       [{matcher: "mcp__plugin_provider_provider__switch_profile", hooks: [{type: "command", command: "~/.claude/swap-credentials.sh auto-swap"}]}])
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"

  chmod 600 "$settings"
  ok "SessionStart + PostToolUse hooks merged"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: provider profile files
# ─────────────────────────────────────────────────────────────────────────────
ensure_profile_files() {
  header "5/6  provider profile files"

  if [[ ! -f "$CLAUDE_DIR/settings.anthropic.json" ]]; then
    echo '{"env":{}}' > "$CLAUDE_DIR/settings.anthropic.json"
    ok "created settings.anthropic.json (empty env)"
  else
    ok "settings.anthropic.json exists"
  fi

  if [[ ! -f "$CLAUDE_DIR/settings.anthropic-team.json" ]]; then
    cp "$CLAUDE_DIR/settings.anthropic.json" "$CLAUDE_DIR/settings.anthropic-team.json"
    ok "created settings.anthropic-team.json"
  else
    ok "settings.anthropic-team.json exists"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: credential capture (interactive)
# ─────────────────────────────────────────────────────────────────────────────
capture_credentials() {
  header "6/6  credential capture"

  local missing=()
  for p in anthropic anthropic-team; do
    [[ -f "$CLAUDE_DIR/credentials.${p}.json" ]] || missing+=("$p")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "both anthropic and anthropic-team credentials already saved"
    echo
    "$CLAUDE_DIR/refresh-credentials.sh" check || true
    return
  fi

  warn "missing credentials for: ${missing[*]}"
  echo
  echo "To capture credentials manually:"
  echo "  1. Ensure you are logged in to Claude Code as the desired plan:"
  echo "       claude auth status"
  echo "  2. Save it into the matching profile name (anthropic or anthropic-team):"
  echo "       ~/.claude/swap-credentials.sh save <profile>"
  echo "  3. Log out and log in to the OTHER plan, then save it too:"
  echo "       claude auth logout && claude auth login"
  echo "       ~/.claude/swap-credentials.sh save <other-profile>"
  echo "  4. Verify:"
  echo "       ~/.claude/refresh-credentials.sh check"
  echo
  echo "If you are logged in now, would you like to save the current credential?"
  read -r -p "   Save current credential as which profile? (anthropic / anthropic-team / skip): " choice
  case "$choice" in
    anthropic|anthropic-team)
      "$CLAUDE_DIR/swap-credentials.sh" save "$choice"
      ;;
    *)
      warn "skipped — run the steps above manually later"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}"
  echo "Claude-provider multi-plan setup"
  echo -e "${RESET}"
  echo "target: $CLAUDE_DIR"
  echo "fork:   $REPO_URL ($REPO_BRANCH)"
  echo

  check_prerequisites
  install_plugin
  install_helper_scripts
  configure_hooks
  ensure_profile_files
  capture_credentials

  echo
  ok "${BOLD}setup complete${RESET}"
  echo
  echo -e "${BOLD}next steps:${RESET}"
  echo "  cpr --list                   # should show anthropic, anthropic-team, (namc), etc."
  echo "  cpr anthropic-team           # switch to Team plan"
  echo "  claude auth status           # verify subscriptionType"
  echo "  ~/.claude/refresh-credentials.sh check"
}

main "$@"
