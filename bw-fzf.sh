#!/bin/bash

trap 'trap - INT; kill -s HUP -- -$$' INT
trap 'cleanup' EXIT

ITEMS=
TIMEOUT=60s
SEARCH_TERM=

function cleanup() {
  unset BW_SESSION
  reset
}

function ask_password() {
  local password session

  if command -v systemd-ask-password &>/dev/null; then
    password=$(systemd-ask-password "Password: ")
  else
    read -s -p "Password [hidden]: " password
    echo
  fi

  export BW_SESSION=$(echo "$password" | bw unlock --raw 2>/dev/null)
  if [[ -z "$BW_SESSION" ]]; then
    echo "Could not unlock vault"
    exit 1
  else
    echo "Unlocked!"
  fi
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
  local log_file temp_file prompt

  log_file=$(mktemp)
  echo "$ITEMS" | jq '.' >"$log_file"

  temp_file=$(mktemp)
  echo "$ITEMS" >"$temp_file"

  chmod 600 "$temp_file" "$log_file"

  if [ -n "$SEARCH_TERM" ]; then
    prompt="bw-fzf (filter: $SEARCH_TERM) ➜ "
  else
    prompt="bw-fzf ➜ "
  fi

  jq -r '.[] | "\(.name) (\(.id)) \(.login.username)"' "$temp_file" |
    FZF_PREVIEW_FILE="$temp_file" fzf --cycle --inline-info --ansi --no-mouse --layout=reverse --prompt="$prompt" \
      --preview='
            item_id=$(echo {} | sed -n "s/.*(\(.*\)).*/\1/p")
            item=$(jq -r --arg id "$item_id" ".[] | select(.id == \$id)" "$FZF_PREVIEW_FILE")
            username=$(echo "$item" | jq -r ".login.username | @sh")
            password=$(echo "$item" | jq -r ".login.password | @sh")
            notes=$(echo "$item" | jq -r ".notes // empty | @sh")
            creationDate=$(echo "$item" | jq -r ".creationDate | @sh")
            revisionDate=$(echo "$item" | jq -r ".revisionDate | @sh")
            uris=$(echo "$item" | jq -r ".login.uris[].uri | @sh" | sed "s/^/- /")

            totp_available=$(echo "$item" | jq -r ".login.totp != null")

            if [ "$totp_available" = "true" ]; then
                clear
                totp_secret=$(echo "$item" | jq -r ".login.totp")
                if command -v oathtool &> /dev/null; then
                    totp=$(oathtool --totp -b "$totp_secret")
                else
                    totp=$(bw get totp "$item_id")
                fi
            else
                totp="No TOTP available for this login."
            fi

            bold=$(tput bold)
            normal=$(tput sgr0)
            cyan=$(tput setaf 6)

            printf "${bold}${cyan}username:${normal} %s\n${bold}${cyan}password:${normal} %s\n${bold}${cyan}totp:${normal} %s\n${bold}${cyan}notes:${normal} %s\n${bold}${cyan}creationDate:${normal} %s\n${bold}${cyan}revisionDate:${normal} %s\n${bold}${cyan}uris:${normal}\n%s" \
                   "$username" "$password" "$totp" "$notes" "$creationDate" "$revisionDate" "$uris"
        '

  rm "$temp_file" "$log_file"
}

function install_script() {
  local install_path="/usr/local/bin/bw-fzf"

  if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root. Try using sudo."
    exit 1
  fi

  if cp "$0" "$install_path" && chmod +x "$install_path"; then
    echo "Successfully installed to $install_path"
  else
    echo "Failed to install. Check your permissions."
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
  echo "  -i, --install    Install the script to /usr/local/bin"
  echo "  -h, --help       Show this help message"
  echo "  -t, --timeout    Set custom timeout (e.g., 30s, 1m). Default is 1 minute."
  echo "  -s, --search     Search term to filter items"
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

  (sleep "$TIMEOUT" && kill $$) &

  ask_password
  load_items "$SEARCH_TERM"
  bw_list
}

main "$@"
