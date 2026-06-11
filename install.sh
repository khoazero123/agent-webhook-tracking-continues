#!/usr/bin/env bash
set -euo pipefail

REPO_HTTPS="https://github.com/khoazero123/agent-webhook-tracking-continues.git"
RAW_BASE="https://raw.githubusercontent.com/khoazero123/agent-webhook-tracking-continues/main"

info() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32mOK  %s\033[0m\n' "$1"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$1"; }

get_repo_root() {
  local script_dir=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [[ -n "$script_dir" && -f "$script_dir/runtime/unix/hook_common.py" ]]; then
    printf '%s' "$script_dir"
    return 0
  fi

  info "Downloading repo to a temp directory..."
  local temp_root
  temp_root="$(mktemp -d)"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_HTTPS" "$temp_root/repo" >/dev/null
    printf '%s' "$temp_root/repo"
    return 0
  fi

  local zip_path="$temp_root/repo.zip"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/archive/refs/heads/main.zip" -o "$zip_path"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$zip_path" "$RAW_BASE/archive/refs/heads/main.zip"
  else
    echo "curl, wget, or git is required to download the repo." >&2
    exit 1
  fi

  unzip -q "$zip_path" -d "$temp_root"
  printf '%s' "$temp_root/agent-webhook-tracking-continues-main"
}

prompt_webhook_url() {
  echo
  echo "Webhook URL (leave empty to disable webhooks):"
  read -r -p "Webhook URL: " url || true
  url="${url//$'\r'/}"
  printf '%s' "$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

prompt_keywords() {
  local defaults="$1"
  local locale="$2"
  echo
  echo "Auto-continue keywords (comma-separated, Enter = default):"
  echo "Detected locale: $locale"
  echo "Default: $defaults"
  read -r -p "Keywords: " input || true
  input="${input//$'\r'/}"
  if [[ -z "$input" ]]; then
    printf '%s' "$defaults"
    return 0
  fi
  printf '%s' "$input"
}

prompt_yes_no() {
  local question="$1"
  local default_yes="$2"
  local suffix answer
  if [[ "$default_yes" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  read -r -p "$question $suffix: " answer || true
  answer="${answer//$'\r'/}"
  if [[ -z "$answer" ]]; then
    [[ "$default_yes" == "yes" ]]
    return $?
  fi
  case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "python3"
  elif command -v python >/dev/null 2>&1; then
    printf '%s' "python"
  else
    echo ""
  fi
}

resolve_locale_defaults() {
  local repo_root="$1"
  local py="$2"
  local defaults_file="$repo_root/config.defaults.json"
  "$py" "$repo_root/scripts/locale_defaults.py" resolve auto "$defaults_file"
}

write_hook_config() {
  local target_dir="$1"
  local webhook_url="$2"
  local source="$3"
  local keywords_csv="$4"
  local tail_length="$5"
  local max_loops="$6"
  local continue_message="$7"

  python3 - "$target_dir" "$webhook_url" "$source" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message" <<'PY'
import json
import sys
from pathlib import Path

target_dir, webhook_url, source, keywords_csv, tail_length, max_loops, continue_message = sys.argv[1:8]
keywords = [k.strip() for k in keywords_csv.split(",") if k.strip()]
config = {
    "source": source,
    "webhook_url": webhook_url,
    "keywords": keywords,
    "tail_length": int(tail_length),
    "continue_message": continue_message,
    "max_continue_loops": int(max_loops),
}
Path(target_dir, "hook-config.json").write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
}

install_cursor_hooks() {
  local repo_root="$1"
  local webhook_url="$2"
  local keywords_csv="$3"
  local py="$4"
  local tail_length="$5"
  local max_loops="$6"
  local continue_message="$7"
  local cursor_root="$HOME/.cursor"
  local hooks_dir="$cursor_root/hooks"

  mkdir -p "$hooks_dir"
  cp "$repo_root/runtime/unix/"*.py "$hooks_dir/"
  chmod +x "$hooks_dir/"*.py

  write_hook_config "$hooks_dir" "$webhook_url" "cursor" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"

  cat > "$cursor_root/hooks.json" <<EOF
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [
      { "command": "$py ./hooks/cursor_before_prompt.py", "timeout": 15 }
    ],
    "afterAgentResponse": [
      { "command": "$py ./hooks/cursor_after_response.py", "timeout": 15 }
    ],
    "stop": [
      { "command": "$py ./hooks/cursor_stop.py", "timeout": 10, "loop_limit": $max_loops }
    ]
  }
}
EOF
  ok "Installed Cursor hooks at $hooks_dir"
}

install_codex_hooks() {
  local repo_root="$1"
  local webhook_url="$2"
  local keywords_csv="$3"
  local py="$4"
  local tail_length="$5"
  local max_loops="$6"
  local continue_message="$7"
  local codex_root="$HOME/.codex"
  local hooks_dir="$codex_root/hooks"

  mkdir -p "$hooks_dir"
  cp "$repo_root/runtime/unix/"*.py "$hooks_dir/"
  chmod +x "$hooks_dir/"*.py

  write_hook_config "$hooks_dir" "$webhook_url" "codex" "$keywords_csv" "$tail_length" "$max_loops" "$continue_message"

  cat > "$codex_root/hooks.json" <<EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$py $hooks_dir/codex_user_prompt.py",
            "timeout": 15,
            "statusMessage": "Webhook user prompt"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$py $hooks_dir/codex_stop.py",
            "timeout": 15,
            "statusMessage": "Webhook + auto continue"
          }
        ]
      }
    ]
  }
}
EOF
  ok "Installed Codex hooks at $hooks_dir"
  warn "In Codex, run /hooks to trust hooks after installing."
}

main() {
  echo
  echo "Agent Webhook + Auto Continue Installer (Unix)"
  echo "=============================================="

  local repo_root py defaults_json locale default_keywords keywords_input keywords_csv
  local tail_length max_loops continue_message webhook_url
  repo_root="$(get_repo_root)"

  py="$(python_bin)"
  if [[ -z "$py" ]]; then
    echo "python3 is required to run hooks on Linux/macOS." >&2
    exit 1
  fi

  info "Scanning Cursor/Codex transcripts to detect conversation language..."
  defaults_json="$(resolve_locale_defaults "$repo_root" "$py")"
  locale="$(echo "$defaults_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['locale'])")"
  default_keywords="$(echo "$defaults_json" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin)['keywords']))")"
  continue_message="$(echo "$defaults_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['continue_message'])")"
  tail_length="$(echo "$defaults_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['tail_length'])")"
  max_loops="$(echo "$defaults_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_continue_loops'])")"
  ok "Using $locale defaults (continue message: $continue_message)"

  webhook_url="$(prompt_webhook_url)"
  keywords_input="$(prompt_keywords "$default_keywords" "$locale")"
  keywords_csv="$keywords_input"

  local install_cursor=no install_codex=no
  if prompt_yes_no "Install for Cursor?" yes; then install_cursor=yes; fi
  if prompt_yes_no "Install for Codex?" yes; then install_codex=yes; fi

  if [[ "$install_cursor" != "yes" && "$install_codex" != "yes" ]]; then
    warn "No tools selected. Exiting."
    exit 1
  fi

  if [[ "$install_cursor" == "yes" ]]; then
    install_cursor_hooks "$repo_root" "$webhook_url" "$keywords_csv" "$py" "$tail_length" "$max_loops" "$continue_message"
  fi

  if [[ "$install_codex" == "yes" ]]; then
    install_codex_hooks "$repo_root" "$webhook_url" "$keywords_csv" "$py" "$tail_length" "$max_loops" "$continue_message"
  fi

  echo
  ok "Installation complete. Restart Cursor/Codex to apply hooks."
  if [[ -z "$webhook_url" ]]; then
    warn "Webhooks disabled (empty URL). Auto-continue only."
  fi
}

main "$@"
