#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
DISCORD_API_BASE="https://discord.com/api/v10"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

read_env_value() {
  local key="$1" value
  value="$(awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      exit
    }
  ' "$ENV_FILE")"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

discord_request() {
  local method="$1" path="$2" payload="${3:-}"
  local args=(
    -sS
    -X "$method"
    -H "Authorization: Bot $DISCORD_BOT_TOKEN"
    -H 'Content-Type: application/json'
  )
  if [[ -n "$payload" ]]; then
    args+=(-d "$payload")
  fi
  curl "${args[@]}" "$DISCORD_API_BASE$path"
}

usage() {
  cat <<'USAGE'
Usage:
  tool/discord_release.sh history [limit]
  tool/discord_release.sh validate <message-file>
  tool/discord_release.sh publish <message-file>
USAGE
}

require_command awk
require_command curl
require_command jq
[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

DISCORD_BOT_TOKEN="$(read_env_value DISCORD_BOT_TOKEN)"
DISCORD_GUILD_ID="$(read_env_value DISCORD_GUILD_ID)"
DISCORD_RELEASE_CHANNEL_ID="$(read_env_value DISCORD_RELEASE_CHANNEL_ID)"

[[ -n "$DISCORD_BOT_TOKEN" ]] || fail 'DISCORD_BOT_TOKEN is missing'
[[ "$DISCORD_GUILD_ID" =~ ^[0-9]+$ ]] || fail 'DISCORD_GUILD_ID is invalid'
[[ "$DISCORD_RELEASE_CHANNEL_ID" =~ ^[0-9]+$ ]] \
  || fail 'DISCORD_RELEASE_CHANNEL_ID is invalid'

COMMAND="${1:-}"
case "$COMMAND" in
  history)
    LIMIT="${2:-10}"
    [[ "$LIMIT" =~ ^[0-9]+$ ]] || fail 'History limit must be numeric'
    (( LIMIT >= 1 && LIMIT <= 100 )) || fail 'History limit must be 1-100'
    RESPONSE="$(discord_request GET "/channels/$DISCORD_RELEASE_CHANNEL_ID/messages?limit=$LIMIT")"
    jq -e 'type == "array"' >/dev/null <<< "$RESPONSE" \
      || fail "Discord history request failed: $(jq -r '.message // "unknown error"' <<< "$RESPONSE")"
    jq -r '.[] | "\(.timestamp)  \(.author.username)  \(.id)\n\(.content)\n---"' \
      <<< "$RESPONSE"
    ;;
  validate|publish)
    MESSAGE_FILE="${2:-}"
    [[ -n "$MESSAGE_FILE" ]] || fail 'Message file is required'
    [[ -f "$MESSAGE_FILE" ]] || fail "Message file not found: $MESSAGE_FILE"
    CONTENT="$(<"$MESSAGE_FILE")"
    CONTENT_LENGTH="$(printf '%s' "$CONTENT" | jq -Rs 'length')"
    (( CONTENT_LENGTH > 0 )) || fail 'Discord message is empty'
    (( CONTENT_LENGTH <= 2000 )) \
      || fail "Discord message exceeds 2000 characters: $CONTENT_LENGTH"

    CHANNEL="$(discord_request GET "/channels/$DISCORD_RELEASE_CHANNEL_ID")"
    [[ "$(jq -r '.guild_id // empty' <<< "$CHANNEL")" == "$DISCORD_GUILD_ID" ]] \
      || fail 'Configured release channel is not in the configured guild'

    if [[ "$COMMAND" == 'validate' ]]; then
      printf 'Validated Discord release message: channel=#%s, characters=%s\n' \
        "$(jq -r '.name' <<< "$CHANNEL")" "$CONTENT_LENGTH"
      exit 0
    fi

    PAYLOAD="$(jq -n --arg content "$CONTENT" '{content: $content}')"
    RESPONSE="$(discord_request POST "/channels/$DISCORD_RELEASE_CHANNEL_ID/messages" "$PAYLOAD")"
    MESSAGE_ID="$(jq -r '.id // empty' <<< "$RESPONSE")"
    [[ -n "$MESSAGE_ID" ]] \
      || fail "Discord publish failed: $(jq -r '.message // "unknown error"' <<< "$RESPONSE")"
    printf 'Published Discord release message: %s\n' "$MESSAGE_ID"
    printf 'URL: https://discord.com/channels/%s/%s/%s\n' \
      "$DISCORD_GUILD_ID" "$DISCORD_RELEASE_CHANNEL_ID" "$MESSAGE_ID"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
