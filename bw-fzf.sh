#!/bin/bash

trap 'exit_handler' INT TERM
trap 'cleanup' EXIT

ITEMS=
TIMEOUT=60s
SEARCH_TERM=
SESSION_FILE="$HOME/.bw-fzf-session"
TIMEOUT_PID=
REFRESH_PID=
TIMESTAMP_FILE="/tmp/bw-fzf-active.timestamp"
TEMP_ITEMS_FILE=
NO_PREVIEW=0

# Determine the clipboard command based on the session type
if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
  CLIP_COMMAND="wl-copy"
  CLIP_ARGS=""
elif [[ $(uname) == "Darwin" ]]; then
  CLIP_COMMAND="pbcopy"
  CLIP_ARGS=""
else
  CLIP_COMMAND="xclip"
  CLIP_ARGS="-selection clipboard"
fi

export PYTHON_TOTP_SCRIPT='
import sys, urllib.parse, base64, hmac, hashlib, struct, time, re

args = sys.argv[1:]
raw_only = "--raw" in args
clean_args = [a for a in args if a != "--raw"]
raw = clean_args[0].strip() if clean_args else ""

if not raw or raw == "null":
    print("No TOTP available" if not raw_only else "")
    sys.exit(0)

secret = urllib.parse.parse_qs(urllib.parse.urlparse(raw).query).get("secret", [raw])[0] if raw.startswith("otpauth://") else raw
secret = re.sub(r"\s+", "", secret).upper()
secret += "=" * ((8 - len(secret) % 8) % 8)

try:
    key = base64.b32decode(secret)
    now = int(time.time())
    remaining = 30 - (now % 30)
    msg = struct.pack(">Q", now // 30)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    o = h[-1] & 0x0F
    code = (struct.unpack(">I", h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
    if raw_only:
        print(f"{code:06d}")
    else:
        print(f"{code:06d} [{remaining}s]")
except Exception:
    print("Invalid Secret" if not raw_only else "")
'

function exit_handler() {
  trap - INT TERM
  cleanup
  exit 1
}

function cleanup() {
  if [[ -n "$TIMEOUT_PID" ]]; then
    kill "$TIMEOUT_PID" 2>/dev/null || true
    wait "$TIMEOUT_PID" 2>/dev/null || true
  fi

  if [[ -n "$REFRESH_PID" ]]; then
    kill "$REFRESH_PID" 2>/dev/null || true
    wait "$REFRESH_PID" 2>/dev/null || true
  fi

  rm -f "$TIMESTAMP_FILE" 2>/dev/null
  rm -f "$TEMP_ITEMS_FILE" 2>/dev/null

  pkill -P $$ 2>/dev/null || true
  wait 2>/dev/null || true
}

function monitor_inactivity() {
  rm -f "$TIMESTAMP_FILE"
  touch "$TIMESTAMP_FILE"

  local timeout_sec
  case "$TIMEOUT" in
    *s) timeout_sec="${TIMEOUT%s}" ;;
    *m) timeout_sec=$((${TIMEOUT%m} * 60)) ;;
    *h) timeout_sec=$((${TIMEOUT%h} * 3600)) ;;
    *)  timeout_sec="$TIMEOUT" ;;
  esac

  while true; do
    sleep 1
    if [[ -f "$TIMESTAMP_FILE" ]]; then
      mod_time=$(date -r "$TIMESTAMP_FILE" +%s 2>/dev/null || stat -f %m "$TIMESTAMP_FILE" 2>/dev/null || stat -c %Y "$TIMESTAMP_FILE" 2>/dev/null)
      current_time=$(date +%s)
      time_diff=$((current_time - mod_time))

      if [[ $time_diff -ge $timeout_sec ]]; then
        echo -e "\nSession timed out after ${TIMEOUT}"
        cleanup
        exit 1
      fi
    fi
  done &
  TIMEOUT_PID=$!
}

export -f monitor_inactivity 2>/dev/null || true

function check_session() {
  if [[ -n "${BW_SESSION}" ]]; then
    if bw unlock --check --quiet 2>/dev/null; then
      echo "Using existing session from environment"
      return 0
    fi
  fi

  if [[ -f "$SESSION_FILE" ]]; then
    export BW_SESSION=$(cat "$SESSION_FILE")
    if bw unlock --check --quiet 2>/dev/null; then
      echo "Using existing session from file"
      return 0
    fi
  fi
  return 1
}

function handle_session_save() {
  read -p "Do you want to save this session? [y/N] " save_session
  local session

  session=$(echo "$password" | bw unlock --raw 2>/dev/null)
  if [[ -z "$session" ]]; then
    echo "Could not unlock vault"
    exit 1
  fi

  case $save_session in
  [Yy]*)
    echo "Saving session..."
    echo "$session" >"$SESSION_FILE"
    chmod 600 "$SESSION_FILE"
    echo "Session saved to $SESSION_FILE"
    ;;
  *)
    echo "Session will not be saved"
    ;;
  esac

  export BW_SESSION="$session"
  echo "Unlocked!"
}

function ask_password() {
  local password

  if check_session; then
    return 0
  fi

  if command -v systemd-ask-password &>/dev/null; then
    password=$(systemd-ask-password "Password: ")
  else
    read -s -p "Password [hidden]: " password
    echo
  fi

  handle_session_save
}

function load_items() {
  local search_term="$1"
  echo "Loading items..."
  if [[ -n "$search_term" ]]; then
    if ! ITEMS=$(bw list items --search "$search_term" --session "$BW_SESSION" 2>/dev/null); then
      echo "Could not load items or operation timed out"
      exit 1
    fi
  else
    if ! ITEMS=$(bw list items --session "$BW_SESSION" 2>/dev/null); then
      echo "Could not load items or operation timed out"
      exit 1
    fi
  fi
  echo "Items loaded successfully."
}

function bw_list() {
  local prompt
  local listen_port=$((RANDOM % 10000 + 50000))

  TEMP_ITEMS_FILE=$(mktemp)
  echo "$ITEMS" >"$TEMP_ITEMS_FILE"
  chmod 600 "$TEMP_ITEMS_FILE"

  if [ -n "$SEARCH_TERM" ]; then
    prompt="bw-fzf (filter: $SEARCH_TERM) ➜ "
  else
    prompt="bw-fzf ➜ "
  fi

  monitor_inactivity

  # Background process to force preview refresh every second
  if [ "$NO_PREVIEW" -eq 0 ] && command -v curl &>/dev/null; then
    (
      while kill -0 $$ 2>/dev/null; do
        sleep 1
        curl -s -XPOST "http://127.0.0.1:$listen_port" -d "refresh-preview" >/dev/null 2>&1 || true
      done
    ) &
    REFRESH_PID=$!
  fi

  local HELP_TEXT="
    Keyboard Shortcuts:
    ------------------
    ctrl-h        Show this help window
    ctrl-u        Copy username to clipboard
    ctrl-p        Copy password to clipboard
    ctrl-o        Copy TOTP code to clipboard

    Navigation:
    ----------
    ↑/↓          Select item
    Enter        Select item
    Page Up/Down Scroll preview window
    /            Filter items
    ESC          Clear filter/Exit

    Tips:
    -----
    • Type to filter entries
    • All copied items go to system clipboard
    • Session times out after ${TIMEOUT} of inactivity
    "

  local fzf_args=(
    --listen="$listen_port"
    --cycle
    --inline-info
    --ansi
    --no-mouse
    --layout=reverse
    --prompt="$prompt"
    --bind="change:execute-silent(touch $TIMESTAMP_FILE)"
    --bind="focus:execute-silent(touch $TIMESTAMP_FILE)"
    --bind="ctrl-u:execute(item_id=\$(echo {} | sed -n 's/.*(\(.*\)).*/\1/p'); username=\$(jq -r --arg id \"\$item_id\" '.[] | select(.id == \$id) | .login.username' \"$TEMP_ITEMS_FILE\"); echo -n \"\$username\" | $CLIP_COMMAND $CLIP_ARGS)+execute-silent(touch $TIMESTAMP_FILE)"
    --bind="ctrl-p:execute(item_id=\$(echo {} | sed -n 's/.*(\(.*\)).*/\1/p'); password=\$(jq -r --arg id \"\$item_id\" '.[] | select(.id == \$id) | .login.password' \"$TEMP_ITEMS_FILE\"); echo -n \"\$password\" | $CLIP_COMMAND $CLIP_ARGS)+execute-silent(touch $TIMESTAMP_FILE)"
    --bind="ctrl-o:execute(item_id=\$(echo {} | sed -n 's/.*(\(.*\)).*/\1/p'); totp_secret=\$(jq -r --arg id \"\$item_id\" '.[] | select(.id == \$id) | .login.totp' \"$TEMP_ITEMS_FILE\"); totp=\$(python3 -c \"\$PYTHON_TOTP_SCRIPT\" --raw \"\$totp_secret\"); echo -n \"\$totp\" | $CLIP_COMMAND $CLIP_ARGS)+execute-silent(touch $TIMESTAMP_FILE)"
  )

  # If preview is disabled, set a blank preview and hide the preview window.
  # Otherwise, use the standard item preview.
  if [ "$NO_PREVIEW" -eq 1 ]; then
    fzf_args+=(
      --header="Press ctrl-h for help"
      --preview=""
      --preview-window=hidden
    )
  else
    fzf_args+=(
      --header="Press ctrl-h for help"
      --preview-window='right:50%'
      --preview='
        if [[ "{}" == "HELP" ]]; then
            echo "'"$HELP_TEXT"'"
        else
            item_id=$(echo {} | sed -n "s/.*(\(.*\)).*/\1/p")
            item=$(jq -r --arg id "$item_id" ".[] | select(.id == \$id)" "'"$TEMP_ITEMS_FILE"'")

            username=$(jq -r ".login.username" <<< $item)
            password=$(jq -r ".login.password" <<< $item)
            notes=$(jq -r ".notes // empty" <<< $item)
            creationDate=$(jq -r ".creationDate" <<< $item)
            revisionDate=$(jq -r ".revisionDate" <<< $item)
            uris=$(jq -r ".login.uris[]?.uri // empty" <<< "$item" | sed "s/^/  • /")

            totp_secret=$(jq -r ".login.totp // empty" <<< "$item")
            totp=$(python3 -c "$PYTHON_TOTP_SCRIPT" "$totp_secret")

            bold=$(tput bold)
            normal=$(tput sgr0)
            cyan=$(tput setaf 6)
            red=$(tput setaf 1)
            underline=$(tput smul)
            nounderline=$(tput rmul)
            padding="  "

            printf "\n${padding}${bold}${underline}Login Details${nounderline}${normal}\n\n"
            printf "${padding}${bold}${cyan}Username${normal}\n${padding}  %s\n\n" "$username"
            printf "${padding}${bold}${cyan}Password${normal}\n${padding}  ${red}%s${normal}\n\n" "$password"
            printf "${padding}${bold}${cyan}TOTP${normal}\n${padding}  %s\n\n" "$totp"
            printf "${padding}${bold}${cyan}Notes${normal}\n${padding}  %s\n\n" "$notes"
            printf "${padding}${bold}${cyan}URIs${normal}\n%s\n\n" "$uris"
            printf "${padding}${bold}${cyan}Created${normal}\n${padding}  %s\n" "$creationDate"
            printf "${padding}${bold}${cyan}Modified${normal}\n${padding}  %s\n" "$revisionDate"
        fi
      '
    )
  fi

  fzf_args+=(--bind="ctrl-h:preview(echo \"$HELP_TEXT\")")

  jq -r '.[] | "\(.name) (\(.id)) \(.login.username)"' "$TEMP_ITEMS_FILE" |
    FZF_PREVIEW_FILE="$TEMP_ITEMS_FILE" fzf "${fzf_args[@]}"
}

function install_script() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/bw-fzf"

  if [[ ! -d "$install_dir" ]]; then
    mkdir -p "$install_dir"
  fi

  if cp "$0" "$install_path" && chmod +x "$install_path"; then
    echo "Successfully installed to $install_path"
    case ":$PATH:" in
      *":$install_dir:"*) ;;
      *)
        echo "Add this line to ~/.bashrc or ~/.zshrc"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
    esac
  else
    echo "Failed to install to $install_path"
    exit 1
  fi
}

function help() {
  echo "bw-fzf - A Bitwarden cli wrapper with fzf"
  echo "Project url: https://github.com/radityaharya/bw-fzf"
  echo "Author: Raditya Harya <contact@radityaharya.com>"
  echo
  echo "Usage: bw-fzf [OPTIONS]"
  echo
  echo "Options:"
  echo "  -i, --install    Install the script to ~/.local/bin"
  echo "  -h, --help       Show this help message"
  echo "  -t, --timeout    Set custom timeout (e.g., 30s, 2m, 1h). Default is 60s."
  echo "  -s, --search     Search term to filter items"
  echo "  -n, --no-preview Disable preview window"
  echo
}

function main() {
  while [[ "$1" != "" ]]; do
    case $1 in
    -i | --install)
      install_script
      exit 0
      ;;
    -h | --help)
      help
      exit 0
      ;;
    -t | --timeout)
      shift
      TIMEOUT="$1"
      ;;
    -s | --search)
      shift
      SEARCH_TERM="$1"
      ;;
    -n | --no-preview)
      NO_PREVIEW=1
      ;;
    *)
      echo "Invalid option: $1"
      help
      exit 1
      ;;
    esac
    shift
  done

  if ! command -v bw >/dev/null; then
    echo "Bitwarden cli is missing. Exiting"
    exit 1
  fi

  if ! command -v jq >/dev/null; then
    echo "jq is missing. Exiting"
    exit 1
  fi

  if ! command -v fzf >/dev/null; then
    echo "fzf is missing. Exiting"
    exit 1
  fi

  if ! command -v python3 >/dev/null; then
    echo "python3 is missing. Exiting"
    exit 1
  fi

  if ! command -v curl >/dev/null; then
    echo "curl is missing. Exiting"
    exit 1
  fi

  if ! command -v $CLIP_COMMAND >/dev/null; then
    echo "WARNING: $CLIP_COMMAND is missing. Copy functionality will be unavailable"
  fi

  monitor_inactivity

  ask_password
  load_items "$SEARCH_TERM"
  bw_list
}

main "$@"
