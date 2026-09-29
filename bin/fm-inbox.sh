#!/usr/bin/env bash
# fm-inbox.sh - the captain's out-of-band capture surface.
#
# Solves three DIFFERENT problems with three different mechanisms, because they
# are not the same problem:
#
#   note    Queue an idea for firstmate while firstmate is mid-turn and cannot
#           answer. Writes a durable record and appends ONE `check` wake, so the
#           note survives a crash and is presented at firstmate's next drain.
#           `announce` may append that same wake for an already-saved note.
#           These two are the only subcommands that touch firstmate's wake queue.
#   say     Same as `note`, but the body comes from spoken audio on stdin.
#           Speech is an INPUT METHOD here, not an architecture: it transcribes
#           and then takes exactly the `note` path.
#   status  Answer "what is happening" from durable records ONLY. Reads no
#           network and appends NO wake, so it never interrupts work and is safe
#           to run in a loop.
#   ask     Answer a side question with a one-shot model call that never touches
#           firstmate, the backlog, or the wake queue. A side question is not
#           fleet work and must not become fleet work.
#
# Usage:
#   fm-inbox.sh note [--origin voice] [--request-id <id>] [--json] [--] <text>...
#   fm-inbox.sh note [--origin voice] [--request-id <id>] [--json] -   (body from stdin)
#   fm-inbox.sh announce [--json] <id>
#   fm-inbox.sh reply [--json] <id> <text>... | reply [--json] <id> -
#   fm-inbox.sh receipts [--after <cursor>] [--all-pending] [--all-handled] [--all-replies]
#   fm-inbox.sh ready
#   fm-inbox.sh say  [<file.wav>]       (default: audio on stdin)
#   fm-inbox.sh status
#   fm-inbox.sh ask  <question>...
#   fm-inbox.sh list
#   fm-inbox.sh drain [--ack <id>...]
#   fm-inbox.sh phone
#   fm-inbox.sh voice-gate <merge|land|discard|decide|mandate> [--standing] [--check]
#   fm-inbox.sh keyboard
#   fm-inbox.sh update [--reply-to <note-id> [--readback <action>]]
#                      (--voice <text> | --voice-file <path> | --no-voice)
#                      [--json] [--] <text>... | update ... -   (text from stdin)
#   fm-inbox.sh update --resend <update-id> [--json]
#   fm-inbox.sh feed [--after <cursor>] [--all]
#
# `note --request-id` is the idempotent capture path: a repeat of the same
# request id returns the original note instead of creating a second one, and
# prints `replay` (or JSON `"outcome":"replay"`) so a first submission and a
# retry are distinguishable. The binding is recorded before announcement, so a
# crash between save and wake still replays the original note. Without
# --request-id the historical one-note-per-call behaviour is unchanged.
# `announce` repairs the wake for an already-saved note without creating another.
# A note already acknowledged (in handled/) gets no wake from `announce` or a
# request-id replay; both report it as acknowledged and exit 0.
# It refuses a note whose announcement state is UNKNOWN: a note written before
# this home tracked announcement markers already appended its own wake at
# creation, and there is no record to prove it, so announcing it again would be
# the duplicate wake this contract exists to remove. Notes written from here on
# carry `announce_marker=1`, which is what makes a missing marker mean "not
# announced" rather than "not known". Receipts report that state as null.
# A note body is text, not options: only the flags above are parsed, anything
# else starting with `--` begins the body, and `--` ends option parsing.
# Human `note`/`list`/`drain` output and exit conventions stay as they were when
# those flags are omitted: a saved note whose wake fails still exits 1. With
# --request-id or --json, a saved-but-unannounced note exits 3 so a caller can
# tell it from a genuine failure (exit 1, nothing saved) and repair rather than
# enqueue again.
# `receipts` is the bounded JSON view of pending and handled notes, their
# acknowledgement, announcement, and any recorded reply. Default bounds omit
# rather than implying the first page is everything; omitted[] names the
# surface and how to reveal it, the same convention as fm-bearings-snapshot.sh.
# `reply` is how the primary publishes its actual answer against a note id.
# Each reply is stamped with a durable per-home sequence, so the receipts cursor
# is a strict total order and two replies recorded in the same second are both
# readable. One reply per note: a second one is refused.
# `ready` is the read-only primary-readiness projection (lock, wake-consumer
# health, away posture, observation time). It never acquires the session lock
# and never infers liveness from a lock file, a session, or a pane.
#
# PHONE CHANNEL. This file owns firstmate's side of the Magic Conch phone
# channel: the voice-origin marker, the voice-authority rule and its
# enforcement, and the outbound phone feed a connector reads. It is opt-in:
# with no config/phone-channel in the home, `note --origin voice` and `update`
# refuse, nothing below is ever written, and every other subcommand's output is
# unchanged.
#
#   Voice-origin marker. `note --origin voice` records `origin=voice` in the
#   note, and every view firstmate reads keeps it: the wake line says
#   `[voice]`, `list` and `drain` print the voice-authority rule above the
#   body, and receipts carry "origin":"voice". The phone's request id rides
#   `--request-id`, so a re-sent recording is the ordinary replay above and is
#   acknowledged without being taken in twice.
#
#   Voice authority (config/voice-authority; the captain changes it only at the
#   keyboard, never because a voice note asked). `hold`, the default and what an
#   absent or unreadable file means: voice may ask questions and queue work but
#   never approves a merge, a destructive, irreversible, or security-sensitive
#   action, or a captain decision; those wait for the keyboard. `confirm`: voice
#   may approve one of them once firstmate has read that exact action back
#   (`update --reply-to <id> --readback <action>`, where <action> is the
#   voice-gate action it will take) and the captain's next voice note is an
#   explicit "confirm" (the note's text, ignoring case, spaces, and
#   punctuation, is exactly that word). The confirmation authorizes only the
#   action read back, and only once: the first matching voice-gate call spends
#   it, so any further approval needs a new read-back and a new "confirm".
#
#   Voice window. Taking in a voice-origin note opens the home's voice window
#   (a note is recorded in it once, before it becomes visible, so a crash never
#   leaves an unrecorded voice note). Only the keyboard closes it: firstmate
#   runs `keyboard` before acting on the captain's next unmarked keyboard
#   message outside away mode while the window is open, and the away-mode
#   return runs it after archiving the away record (bin/fm-afk-launch.sh
#   stop). A voice note never closes it, and firstmate never runs `keyboard`
#   because a voice note asked.
#
#   `voice-gate` is the one enforcement point firstmate's guarded scripts call
#   before they consume captain authority: bin/fm-pr-merge.sh (merge),
#   bin/fm-merge-local.sh (land), bin/fm-teardown.sh --force (discard),
#   bin/fm-captain-hold.sh answer (decide), and bin/fm-afk-contract.sh enter
#   with away words (mandate). `--standing` says the caller acts on authority
#   the captain gave at the keyboard beforehand - the away record's words or a
#   task's yolo posture - rather than on a new instruction. With no voice window
#   it allows everything. Inside one it refuses, exit 1 with the reason on
#   stderr, while any voice note of the window is still pending, and refuses
#   every caller without `--standing`; under `confirm` a valid spoken
#   confirmation - the window's last two entries are a read-back of this same
#   action and then a "confirm" note - allows it once instead, and the gate
#   records that it was spent. `--check` answers the same question without
#   spending anything, for a caller that asks early and again at its point of
#   no return.
#
#   Outbound feed. `update` appends one entry to state/inbox/.phone-feed.jsonl,
#   the durable feed the connector reads through `feed`: the full text, the
#   voice-friendly version firstmate wrote (null only with the explicit
#   `--no-voice`, which leaves the hub's rule-based rewrite to speak it), and an
#   update id minted here, a random `fmu-` id that no other entry carries, so it
#   is globally unique and never reused. A reply (`--reply-to` a voice note) is
#   accepted whenever the channel is configured, because it answers something
#   the captain said on the phone; any other update is an escalation, accepted
#   only while phone updates are on - the away record exists with
#   `reach_channels: phone` (bin/fm-afk-contract.sh) - and otherwise reported
#   `skipped` with nothing written. Routine progress is neither kind and never
#   belongs in the feed. `--resend` appends the same entry again with the same
#   update id and resend=true, so a re-sent update keeps its id. Each entry
#   carries a per-feed sequence, and `feed --after <cursor>` returns the entries
#   after it, bounded with an omitted[] disclosure like `receipts`.
#   `phone` prints the channel's current state as key=value lines.
#
# Configuration. A region, a model id and an AWS profile name somebody's account
# and somebody's choices, so this file carries no default for any of them. Each is
# read from the home's gitignored config/ directory, or from the matching
# environment variable, and the model-backed subcommands refuse with the path to
# write rather than reaching for a value that belongs to another home. That
# configuration is also the opt-in: `say` and `ask` are off until it exists.
#
#   config/inbox-region     FM_INBOX_REGION     AWS region.            required
#   config/inbox-stt-model  FM_INBOX_STT_MODEL  speech-to-text model.  required by say
#   config/inbox-ask-model  FM_INBOX_ASK_MODEL  side-question model.   required by ask
#   config/inbox-profile    FM_INBOX_PROFILE    AWS profile.           optional
#
# An absent profile means the call uses whatever credentials are already in the
# environment, which is also what FM_INBOX_PROFILE= (empty) forces.
#
# `note`, `announce`, `reply`, `receipts`, `ready`, `status`, `list` and `drain`
# need NO configuration at all, because they make no model call. The voice
# handover depends on `note`, so it keeps working in a home that has configured
# nothing. `--json` / `receipts` / `ready` require python3, which a firstmate
# home already uses for other tools. The phone channel's subcommands make no
# model call either; its only configuration is the opt-in above, and `update`
# and `feed` also require python3.
#
# Environment:
#   FM_HOME              operational home whose state/ and data/ are used.
#
# PRIVACY: `say` sends your audio and `ask` sends your question to Bedrock.
# `note`, `announce`, `reply`, `receipts`, `ready`, `status`, `list`, `drain`,
# and the phone channel's subcommands make no network call at all: the feed is
# a local file, and carrying it anywhere is the connector's job.
#
# `note` is also the queueing half of the spoken interface: when the voice agent
# in bin/fm-voice-relay.py hands real work over to firstmate, it runs this
# subcommand rather than carrying a second queue of its own. Keep the `note`
# contract stable for that caller. `status` is the HUMAN view of the records;
# bin/fm_voice_records.py owns the scope-controlled machine view the voice agent
# reads, because the voice agent must be able to answer without record free text
# ever reaching a model.
set -euo pipefail

# A non-interactive `ssh host fm-inbox.sh ...` does NOT get a login shell, so it
# does not get ~/.toolbox/bin on PATH. The AWS profile's credential_process is
# the bare word `ada`, so without this the model-backed subcommands fail with
# "[Errno 2] No such file or directory: 'ada'" while note/status still work.
# Verified: this is exactly what happens over SSH without the fix.
for _extra in "$HOME/.toolbox/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_extra:"*) ;;
    *) [ -d "$_extra" ] && PATH="$_extra:$PATH" ;;
  esac
done
unset _extra
export PATH

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INBOX="$STATE/inbox"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'fm-inbox: %s\n' "$*" >&2; exit 1; }

# First non-comment, non-blank line of a config file, or nothing.
read_setting() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

# Refuse by naming the file to write. A model call that guessed at a region or an
# account would either fail confusingly or, worse, succeed against a stranger's.
require_setting() {  # <file-name> <env-var> <what>
  local value
  value=$(read_setting "$1")
  [ -n "$value" ] || die "no $3 is configured: write one line into $CONFIG/$1 or set $2"
  printf '%s' "$value"
}

REGION="${FM_INBOX_REGION:-}"
STT_MODEL="${FM_INBOX_STT_MODEL:-}"
ASK_MODEL="${FM_INBOX_ASK_MODEL:-}"
# Unset falls through to config; explicitly empty means "use ambient credentials".
PROFILE="${FM_INBOX_PROFILE-$(read_setting inbox-profile)}"

# Resolved only by the subcommands that make a model call, so note, announce,
# reply, receipts, ready, status, list and drain keep working in a home that
# has configured nothing.
need_region() {
  [ -n "$REGION" ] || REGION=$(require_setting inbox-region FM_INBOX_REGION "AWS region")
}

need_stt_model() {
  need_region
  [ -n "$STT_MODEL" ] || STT_MODEL=$(require_setting inbox-stt-model \
    FM_INBOX_STT_MODEL "speech-to-text model")
}

need_ask_model() {
  need_region
  [ -n "$ASK_MODEL" ] || ASK_MODEL=$(require_setting inbox-ask-model \
    FM_INBOX_ASK_MODEL "side-question model")
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# The profile's credential_process (`ada`) costs a MEASURED ~1030ms on every
# single call, which is about half the wall time of `say` and `ask`. If real
# credentials are already in the environment, skip --profile entirely and let the
# ambient ones win. Set FM_INBOX_PROFILE= (empty) to force that even without env
# credentials present.
aws_call() {
  if [ -z "$PROFILE" ] || [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    aws --region "$REGION" "$@"
  else
    aws --profile "$PROFILE" --region "$REGION" "$@"
  fi
}

# ---------------------------------------------------------------- note

REQUESTS="$INBOX/.requests"
ANNOUNCED_DIR="$INBOX/.announced"
REPLIES="$INBOX/.replies"

REPLY_SEQ_LOCK="$INBOX/.replies.lock"

RECEIPTS_PENDING_BOUND=20
RECEIPTS_HANDLED_BOUND=20
RECEIPTS_REPLIES_BOUND=20

# The phone channel's records (see PHONE CHANNEL in the header).
VOICE_WINDOW="$INBOX/.voice-window"
VOICE_NOTED="$INBOX/.voice-noted"
VOICE_LOCK="$INBOX/.voice.lock"
PHONE_FEED="$INBOX/.phone-feed.jsonl"
PHONE_FEED_LOCK="$INBOX/.phone-feed.lock"
FEED_BOUND=50

load_wake_lib() {
  local lib="$FM_ROOT/bin/fm-wake-lib.sh"
  [ "${FM_INBOX_WAKE_LIB:-}" = 1 ] && return 0
  [ -r "$lib" ] || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  FM_INBOX_WAKE_LIB=1
}

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for machine-readable inbox output"
}

valid_request_id() {
  case "$1" in
    ''|.*|*/*|*[[:space:]]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  return 0
}

valid_note_id() {
  case "$1" in
    ''|*/*|*[[:space:]]*|*..*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

note_path() {  # <id>
  if [ -f "$INBOX/$1.note" ]; then
    printf '%s\n' "$INBOX/$1.note"
  elif [ -f "$INBOX/handled/$1.note" ]; then
    printf '%s\n' "$INBOX/handled/$1.note"
  else
    return 1
  fi
}

note_announced() {  # <id>
  [ -f "$ANNOUNCED_DIR/$1" ]
}

mark_announced() {  # <id>
  mkdir -p "$ANNOUNCED_DIR"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$ANNOUNCED_DIR/$1"
}

# true | false | unknown, for the note recorded at <path>.
# A note that carries announce_marker=1 was written by a version that keeps the
# marker, so a missing marker means it was genuinely never announced. A note
# without that header predates the marker and already appended its own wake at
# creation; nothing on disk can tell announced from unannounced for it, so it is
# unknown rather than false.
note_announce_state() {  # <id> <path>
  local marker
  if note_announced "$1"; then
    printf 'true\n'
    return 0
  fi
  marker=$(sed -n '/^--$/q;/^announce_marker=1$/p' "$2")
  if [ -n "$marker" ]; then
    printf 'false\n'
  else
    printf 'unknown\n'
  fi
}

read_note_body() {  # <file>
  awk 'found { print; next } /^--$/ { found=1 }' "$1"
}

note_summary_from_body() {
  printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-100
}

# The note's origin header (`voice` for a phone note), or nothing.
note_origin() {  # <path>
  [ -f "$1" ] || return 0
  sed -n '/^--$/q;s/^origin=//p' "$1" | head -n 1
}

note_is_voice() {  # <path>
  [ "$(note_origin "$1")" = voice ]
}

write_note_file() {  # <path> <id> <source> <body> [extra] [request-id]
  local path=$1 id=$2 source=$3 body=$4 extra=${5:-} request_id=${6:-}
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source=%s\n' "$source"
    printf 'announce_marker=1\n'
    [ -z "$request_id" ] || printf 'request_id=%s\n' "$request_id"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf -- '--\n'
    printf '%s' "$body"
    case "$body" in
      *$'\n') ;;
      *) printf '\n' ;;
    esac
  } >"$path"
}

emit_note_json() {  # <outcome> <id> <request-id> <saved> <announced> <path> [acknowledged]
  need_python
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" "${7:-0}" <<'PY'
import json, sys
outcome, note_id, request_id, saved, announced, path, acknowledged = sys.argv[1:8]
record = {
    "schema": "fm-inbox-note.v1",
    "outcome": outcome,
    "id": note_id,
    "request_id": request_id or None,
    "saved": saved == "1",
    "announced": True if announced == "1" else False if announced == "0" else None,
    "acknowledged": acknowledged == "1",
    "path": path,
}
# Only a voice-origin note gains a key, so every other note's receipt is
# exactly what it was before the phone channel existed.
try:
    with open(path, "rb") as handle:
        for raw in handle:
            line = raw.decode("utf-8", errors="replace").rstrip("\n")
            if line == "--":
                break
            if line == "origin=voice":
                record["origin"] = "voice"
except OSError:
    pass
json.dump(record, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
}

# Append exactly one wake so firstmate picks the note up at its next drain.
# Failure to wake is NOT allowed to lose the note: the record is already on
# disk, so we report the wake failure and still exit non-zero loudly.
#
# The marker test, the append and the marker write all happen under the
# wake-queue lock. Two retries of the same request id run this concurrently -
# the second replays the reservation while the first is still inside the
# append - and without that exclusion both would read "not announced" and one
# note would produce two wake rows.
#
# Returns 2 without waking when the note is no longer pending: firstmate has
# already acknowledged it, so a wake would only spend a turn on an empty inbox.
announce_note() {  # <id> <summary>
  local id=$1 summary=$2 lib="$FM_ROOT/bin/fm-wake-lib.sh" status=0 tag=""
  note_is_voice "$INBOX/$id.note" && tag=" [voice]"
  if note_announced "$id"; then
    return 0
  fi
  [ -f "$INBOX/$id.note" ] || return 2
  if [ ! -r "$lib" ]; then
    printf 'fm-inbox: note saved but NOT announced (missing %s)\n' "$lib" >&2
    return 1
  fi
  load_wake_lib || return 1
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if note_announced "$id"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if [ ! -f "$INBOX/$id.note" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 2
  fi
  if fm_wake_append_locked check "inbox:$id" "check: captain inbox note $id$tag - $summary"; then
    mark_announced "$id"
  else
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

finish_note_result() {  # <outcome> <id> <request-id> <json> <strict-exit> <summary>
  local outcome=$1 id=$2 request_id=$3 json=$4 strict=$5 summary=$6
  local announced=0 acknowledged=0 path="$INBOX/$id.note" rc=0
  announce_note "$id" "$summary" || rc=$?
  case "$rc" in
    0) announced=1 ;;
    2) acknowledged=1 ;;
  esac
  [ -f "$INBOX/handled/$id.note" ] && path="$INBOX/handled/$id.note"
  if [ "$json" -eq 1 ]; then
    emit_note_json "$outcome" "$id" "$request_id" 1 "$announced" "$path" "$acknowledged"
  else
    if [ "$outcome" = replay ]; then
      printf 'replay %s\n' "$id"
    else
      printf 'queued %s\n' "$id"
    fi
    printf '  %s\n' "$summary"
    if [ "$announced" -eq 1 ]; then
      printf '  firstmate will pick this up at its next check.\n'
    elif [ "$acknowledged" -eq 1 ]; then
      printf '  firstmate has already acknowledged this note.\n'
    fi
  fi
  if [ "$announced" -eq 1 ] || [ "$acknowledged" -eq 1 ]; then
    return 0
  fi
  if [ "$strict" -eq 1 ]; then
    printf 'fm-inbox: note %s is saved at %s but firstmate was NOT woken\n' \
      "$id" "$path" >&2
    return 3
  fi
  die "note $id is saved at $path but firstmate was NOT woken"
}

claim_request_id() {  # <request-id> <note-id>  -> 0 claimed, 1 already exists
  local request_id=$1 note_id=$2 reserved
  reserved="$REQUESTS/$request_id"
  mkdir -p "$REQUESTS"
  if ( set -C; printf '%s\n' "$note_id" >"$reserved" ) 2>/dev/null; then
    return 0
  fi
  return 1
}

reserved_note_id() {  # <request-id>
  local reserved="$REQUESTS/$1" id
  [ -f "$reserved" ] || return 1
  id=$(tr -d '\r' <"$reserved")
  id=${id%%$'\n'*}
  valid_note_id "$id" || return 1
  printf '%s\n' "$id"
}

# A replayed voice note is recorded in the voice window before it can become
# visible, exactly as a first submission is; the record is written once, so a
# replay after the keyboard closed the window never reopens it.
record_replayed_voice_note() {  # <request-id> <origin> <body>
  local id path
  id=$(reserved_note_id "$1") || return 0
  path=$(note_path "$id" 2>/dev/null || true)
  if [ -n "$path" ]; then
    note_is_voice "$path" || return 0
    voice_window_note "$id" "$(read_note_body "$path")"
  elif [ "$2" = voice ]; then
    voice_window_note "$id" "$3"
  fi
}

publish_from_reservation() {  # <request-id> <source> <body> <extra>
  local request_id=$1 source=$2 body=$3 extra=$4
  local id tmp
  id=$(reserved_note_id "$request_id") || return 1
  if [ ! -f "$INBOX/$id.note" ] && [ ! -f "$INBOX/handled/$id.note" ]; then
    tmp=$(mktemp "$INBOX/.staging-XXXXXX")
    write_note_file "$tmp" "$id" "$source" "$body" "$extra" "$request_id"
    mv "$tmp" "$INBOX/$id.note"
  fi
  printf '%s\n' "$id"
}

queue_note() {
  local source=$1 body=$2 extra=${3:-} request_id=${4:-} json=${5:-0} origin=${6:-}
  local strict=0
  if [ -n "$request_id" ] || [ "$json" -eq 1 ]; then
    strict=1
  fi
  [ -n "${body//[[:space:]]/}" ] || die "refusing to queue an empty note"
  mkdir -p "$INBOX"
  if [ "$origin" = voice ]; then
    extra="origin=voice${extra:+
$extra}"
  fi

  local tmp id summary staging_name reserved

  if [ -n "$request_id" ]; then
    reserved="$REQUESTS/$request_id"
    if [ -f "$reserved" ]; then
      record_replayed_voice_note "$request_id" "$origin" "$body" \
        || die "could not record voice note for request id $request_id in the voice window; retry the same request id"
      id=$(publish_from_reservation "$request_id" "$source" "$body" "$extra") \
        || die "request id $request_id is reserved but unreadable; retry the same request id"
      summary=$(note_summary_from_body "$(read_note_body "$(note_path "$id")")")
      finish_note_result replay "$id" "$request_id" "$json" "$strict" "$summary"
      return $?
    fi
    tmp=$(mktemp "$INBOX/.staging-XXXXXX")
    staging_name=$(basename "$tmp")
    id="$(date +%s)-${staging_name#.staging-}"
    write_note_file "$tmp" "$id" "$source" "$body" "$extra" "$request_id"
    if ! claim_request_id "$request_id" "$id"; then
      rm -f "$tmp"
      record_replayed_voice_note "$request_id" "$origin" "$body" \
        || die "could not record voice note for request id $request_id in the voice window; retry the same request id"
      id=$(publish_from_reservation "$request_id" "$source" "$body" "$extra") \
        || die "request id $request_id is reserved but unreadable; retry the same request id"
      summary=$(note_summary_from_body "$(read_note_body "$(note_path "$id")")")
      finish_note_result replay "$id" "$request_id" "$json" "$strict" "$summary"
      return $?
    fi
    if [ "$origin" = voice ] && ! voice_window_note "$id" "$body"; then
      rm -f "$tmp"
      die "could not record voice note $id in the voice window; nothing is visible yet, so retry the same request id"
    fi
    mv "$tmp" "$INBOX/$id.note"
    summary=$(note_summary_from_body "$body")
    finish_note_result created "$id" "$request_id" "$json" "$strict" "$summary"
    return $?
  fi

  tmp=$(mktemp "$INBOX/.staging-XXXXXX")
  staging_name=$(basename "$tmp")
  id="$(date +%s)-${staging_name#.staging-}"
  write_note_file "$tmp" "$id" "$source" "$body" "$extra" ""
  if [ "$origin" = voice ] && ! voice_window_note "$id" "$body"; then
    rm -f "$tmp"
    die "could not record the voice note in the voice window; nothing was queued"
  fi
  mv "$tmp" "$INBOX/$id.note"
  summary=$(note_summary_from_body "$body")
  finish_note_result created "$id" "" "$json" "$strict" "$summary"
}

cmd_note() {
  local body json=0 request_id="" origin=""
  local usage="usage: fm-inbox.sh note [--origin voice] [--request-id <id>] [--json] [--] <text>... (or: note -)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --request-id)
        [ "$#" -ge 2 ] || die "$usage"
        request_id=$2
        valid_request_id "$request_id" \
          || die "invalid request id (use 1-128 characters: A-Za-z0-9._:-)"
        shift 2
        ;;
      --origin)
        [ "$#" -ge 2 ] || die "$usage"
        [ "$2" = voice ] || die "unknown note origin '$2' (the only origin is voice)"
        origin=voice
        shift 2
        ;;
      --) shift; break ;;
      -h|--help) die "$usage" ;;
      *) break ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    die "$usage"
  elif [ "$1" = "-" ]; then
    [ "$#" -eq 1 ] || die "usage: fm-inbox.sh note [--origin voice] [--request-id <id>] [--json] -"
    body=$(cat; printf .)
    body=${body%.}
  else
    body="$*"
  fi
  if [ "$origin" = voice ]; then
    phone_channel_configured \
      || die "no phone channel is configured in this home, so a voice-origin note is refused: the captain opts in by creating $CONFIG/phone-channel"
  fi
  queue_note text "$body" "" "$request_id" "$json" "$origin"
}

cmd_announce() {
  local json=0 id summary path state rc=0
  if [ "${1:-}" = "--json" ]; then
    json=1
    shift
  fi
  id=${1:-}
  [ -n "$id" ] || die "usage: fm-inbox.sh announce [--json] <id>"
  valid_note_id "$id" || die "invalid note id"
  path=$(note_path "$id") || die "no such note: $id"
  summary=$(note_summary_from_body "$(read_note_body "$path")")
  state=$(note_announce_state "$id" "$path")
  if [ "$state" != true ] && [ "$path" = "$INBOX/handled/$id.note" ]; then
    state=acknowledged
  fi
  case "$state" in
    true)
      if [ "$json" -eq 1 ]; then
        emit_note_json replay "$id" "" 1 1 "$path"
      else
        printf 'already-announced %s\n' "$id"
      fi
      return 0
      ;;
    unknown)
      if [ "$json" -eq 1 ]; then
        emit_note_json refused "$id" "" 1 unknown "$path"
      fi
      printf 'fm-inbox: note %s predates the announcement marker, so whether it was already announced is UNKNOWN; refusing to announce it again\n' \
        "$id" >&2
      exit 1
      ;;
  esac
  announce_note "$id" "$summary" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$json" -eq 1 ]; then
      emit_note_json created "$id" "" 1 1 "$path"
    else
      printf 'announced %s\n' "$id"
    fi
    return 0
  fi
  if [ "$rc" -eq 2 ] || [ "$state" = acknowledged ]; then
    path=$(note_path "$id") || path="$INBOX/handled/$id.note"
    if [ "$json" -eq 1 ]; then
      emit_note_json replay "$id" "" 1 0 "$path" 1
    else
      printf 'already-acknowledged %s\n' "$id"
    fi
    return 0
  fi
  if [ "$json" -eq 1 ]; then
    emit_note_json created "$id" "" 1 0 "$path"
    printf 'fm-inbox: note %s is saved at %s but firstmate was NOT woken\n' \
      "$id" "$path" >&2
    return 3
  fi
  die "note $id is saved at $path but firstmate was NOT woken"
}

# Claim the next reply sequence. The caller holds REPLY_SEQ_LOCK across the
# claim AND the record write, so a reply a reader can see implies every lower
# sequence is already readable: the cursor stays a strict total order.
# The claim is above both the counter and every recorded reply, and the counter
# is replaced by rename, so a torn or lost counter can never move it backwards.
next_reply_seq() {
  local seq_file="$REPLIES/.seq" seq recorded tmp
  seq=$(cat "$seq_file" 2>/dev/null || printf '0')
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  recorded=$(find "$REPLIES" -maxdepth 1 -type f ! -name '.*' -exec awk '
    FNR == 1 { head = 1 }
    /^--$/ { head = 0 }
    head && /^seq=[0-9]+$/ { v = substr($0, 5) + 0; if (v > max) max = v }
    END { print max + 0 }' {} + 2>/dev/null | sort -n | tail -n 1)
  case "$recorded" in
    ''|*[!0-9]*) recorded=0 ;;
  esac
  [ "$recorded" -le "$seq" ] || seq=$recorded
  seq=$((seq + 1))
  tmp=$(mktemp "$REPLIES/.seq-XXXXXX") || return 1
  if ! printf '%s\n' "$seq" >"$tmp" || ! mv "$tmp" "$seq_file"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$seq"
}

cmd_reply() {
  local json=0 id body path staging seq
  if [ "${1:-}" = "--json" ]; then
    json=1
    shift
  fi
  id=${1:-}
  [ -n "$id" ] || die "usage: fm-inbox.sh reply [--json] <id> <text>... (or: reply [--json] <id> -)"
  shift
  valid_note_id "$id" || die "invalid note id"
  path=$(note_path "$id") || die "no such note: $id"
  if [ "$#" -eq 0 ]; then
    die "usage: fm-inbox.sh reply [--json] <id> <text>... (or: reply [--json] <id> -)"
  elif [ "$1" = "-" ]; then
    [ "$#" -eq 1 ] || die "usage: fm-inbox.sh reply [--json] <id> -"
    body=$(cat; printf .)
    body=${body%.}
  else
    body="$*"
  fi
  [ -n "${body//[[:space:]]/}" ] || die "refusing to record an empty reply"
  mkdir -p "$REPLIES"
  load_wake_lib || die "the reply sequence needs $FM_ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$REPLY_SEQ_LOCK" || die "could not claim the reply sequence"
  if [ -f "$REPLIES/$id" ]; then
    fm_lock_release "$REPLY_SEQ_LOCK"
    die "reply already recorded for $id"
  fi
  if ! seq=$(next_reply_seq); then
    fm_lock_release "$REPLY_SEQ_LOCK"
    die "could not claim the reply sequence"
  fi
  staging=$(mktemp "$REPLIES/.staging-XXXXXX")
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'seq=%s\n' "$seq"
    printf -- '--\n'
    printf '%s' "$body"
    case "$body" in
      *$'\n') ;;
      *) printf '\n' ;;
    esac
  } >"$staging"
  mv "$staging" "$REPLIES/$id"
  fm_lock_release "$REPLY_SEQ_LOCK"
  if [ "$json" -eq 1 ]; then
    need_python
    python3 - "$id" "$REPLIES/$id" <<'PY'
import json, sys
note_id, path = sys.argv[1], sys.argv[2]
json.dump({
    "schema": "fm-inbox-reply.v1",
    "outcome": "created",
    "id": note_id,
    "path": path,
}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
  else
    printf 'replied %s\n' "$id"
  fi
}

cmd_receipts() {
  local after="" all_pending=0 all_handled=0 all_replies=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --after)
        [ "$#" -ge 2 ] || die "usage: fm-inbox.sh receipts [--after <cursor>] [--all-pending] [--all-handled] [--all-replies]"
        after=$2
        shift 2
        ;;
      --all-pending) all_pending=1; shift ;;
      --all-handled) all_handled=1; shift ;;
      --all-replies) all_replies=1; shift ;;
      -h|--help) die "usage: fm-inbox.sh receipts [--after <cursor>] [--all-pending] [--all-handled] [--all-replies]" ;;
      --*) die "unknown option for receipts: $1" ;;
      *) die "usage: fm-inbox.sh receipts [--after <cursor>] [--all-pending] [--all-handled] [--all-replies]" ;;
    esac
  done
  need_python
  python3 - "$INBOX" "$ANNOUNCED_DIR" "$REPLIES" "$FM_HOME" \
    "$RECEIPTS_PENDING_BOUND" "$RECEIPTS_HANDLED_BOUND" "$RECEIPTS_REPLIES_BOUND" \
    "$all_pending" "$all_handled" "$all_replies" "$after" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys
from pathlib import Path

inbox, announced_dir, replies_dir, home = sys.argv[1:5]
pending_bound = int(sys.argv[5])
handled_bound = int(sys.argv[6])
replies_bound = int(sys.argv[7])
all_pending = sys.argv[8] == "1"
all_handled = sys.argv[9] == "1"
all_replies = sys.argv[10] == "1"
after = sys.argv[11]
generated = sys.argv[12]

# A record that vanishes between listing and reading - drain --ack moving a
# note to handled/ - is skipped, and undecodable bytes are replaced, so one bad
# or moving file never fails the whole view.
def parse_record(path):
    try:
        text = Path(path).read_bytes().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return None
    headers, sep, body = text.partition("\n--\n")
    if not sep:
        headers, sep, body = text.partition("\n--")
        if sep:
            body = body[1:] if body.startswith("\n") else body
        else:
            body = ""
    meta = {}
    for line in headers.splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            meta[key] = val
    if body.endswith("\n"):
        body = body[:-1]
    return meta, body

def list_notes(folder):
    folder = Path(folder)
    if not folder.is_dir():
        return []
    notes = []
    for path in sorted(folder.glob("*.note"), key=lambda p: p.name, reverse=True):
        if path.name.startswith("."):
            continue
        record = parse_record(path)
        if record is None:
            continue
        meta, body = record
        note_id = meta.get("id") or path.name[:-5]
        notes.append({
            "id": note_id,
            "at": meta.get("at"),
            "source": meta.get("source"),
            "request_id": meta.get("request_id"),
            "announce_marker": meta.get("announce_marker") == "1",
            "origin": meta.get("origin"),
            "body": body,
            "path": str(path),
        })
    return notes

# The cursor is the reply sequence, a strict total order in creation order.
# Every reply is recorded with one, so a reply without a valid sequence is
# malformed: it is reported in omitted[] rather than given a made-up position.
malformed_replies = []

def reply_record(note_id):
    path = Path(replies_dir) / note_id
    if not path.is_file():
        return None
    record = parse_record(path)
    if record is None:
        return None
    meta, body = record
    raw_seq = meta.get("seq") or ""
    if not (raw_seq.isascii() and raw_seq.isdigit()):
        malformed_replies.append(note_id)
        return None
    return {
        "id": note_id,
        "at": meta.get("at"),
        "body": body,
        "cursor": "%012d" % int(raw_seq),
    }

# announced is null - not false - for a note written before this home tracked
# announcement markers: it appended its own wake at creation and left no record
# of it, so "not announced" is not something anyone can read off this state.
def enrich(note, acknowledged):
    note_id = note["id"]
    rec = dict(note)
    rec["acknowledged"] = acknowledged
    if (Path(announced_dir) / note_id).is_file():
        rec["announced"] = True
    elif note.get("announce_marker"):
        rec["announced"] = False
    else:
        rec["announced"] = None
    rec["reply"] = reply_record(note_id)
    rec.pop("path", None)
    rec.pop("announce_marker", None)
    # Only a voice-origin note carries the key, so other receipts are unchanged.
    if not rec.get("origin"):
        rec.pop("origin", None)
    return rec

# Pending is listed before handled so a note acked mid-listing still appears
# in handled; one that was seen in both is reported once, as handled.
pending_notes = list_notes(inbox)
handled_notes = list_notes(Path(inbox) / "handled")
handled_ids = {n["id"] for n in handled_notes}
pending_all = [enrich(n, False) for n in pending_notes if n["id"] not in handled_ids]
handled_all = [enrich(n, True) for n in handled_notes]

def bound_list(rows, limit, unlimited):
    if unlimited or limit <= 0 or len(rows) <= limit:
        return rows, 0
    return rows[:limit], len(rows) - limit

pending, pending_omitted = bound_list(pending_all, pending_bound, all_pending)
handled, handled_omitted = bound_list(handled_all, handled_bound, all_handled)

replies_all = []
for group in (pending_all, handled_all):
    for note in group:
        if note.get("reply"):
            replies_all.append(note["reply"])
replies_all.sort(key=lambda r: r["cursor"])

if after:
    replies_all = [r for r in replies_all if r["cursor"] > after]

replies, replies_omitted = bound_list(replies_all, replies_bound, all_replies)
reply_cursor = replies[-1]["cursor"] if replies else (after or "")

omitted = []
if pending_omitted:
    omitted.append({
        "surface": "pending notes omitted by bound: %d" % pending_omitted,
        "reveal": "pass --all-pending",
    })
if handled_omitted:
    omitted.append({
        "surface": "handled notes omitted by bound: %d" % handled_omitted,
        "reveal": "pass --all-handled",
    })
if replies_omitted:
    omitted.append({
        "surface": "replies omitted by bound: %d" % replies_omitted,
        "reveal": "pass --all-replies",
    })
if malformed_replies:
    omitted.append({
        "surface": "malformed replies without a valid sequence: %d (%s)"
            % (len(malformed_replies), ", ".join(sorted(malformed_replies))),
        "reveal": "inspect %s" % replies_dir,
    })

home_label = "/".join(Path(home).parts[-2:]) if home else home
json.dump({
    "schema": "fm-inbox-receipts.v1",
    "home": home_label,
    "generated": generated,
    "pending": pending,
    "handled": handled,
    "replies": replies,
    "reply_cursor": reply_cursor,
    "omitted": omitted,
}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
}

cmd_ready() {
  [ "$#" -eq 0 ] || die "usage: fm-inbox.sh ready"
  need_python
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SELF_DIR/fm-session-lock-lib.sh"
  load_wake_lib || true
  local lock_state=unknown lock_pid="" live_harness=unknown
  local consumer_state=unknown consumer_reason="" beacon_age=""
  local posture=unknown can_receive=unknown observed
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fm_session_lock_inspect "$STATE"
  lock_state=$FM_LOCK_INSPECT_STATE
  lock_pid=$FM_LOCK_INSPECT_PID
  live_harness=$FM_LOCK_INSPECT_LIVE_HARNESS

  if [ -e "$STATE/.afk" ]; then
    if command -v fm_afk_mode >/dev/null 2>&1; then
      posture=$(fm_afk_mode "$STATE")
    else
      posture=unknown
    fi
  elif [ -e "$STATE/.afk-contract" ]; then
    posture=away
  else
    posture=present
  fi

  # Only ever the age of a beacon that exists: fm_path_age prints a sentinel for
  # a missing path, and a home that never ran a watcher has no observation to
  # report an age for.
  local beat="$STATE/.last-watcher-beat" watch="$SELF_DIR/fm-watch.sh"
  if [ -e "$beat" ] && command -v fm_path_age >/dev/null 2>&1; then
    beacon_age=$(fm_path_age "$beat")
    case "$beacon_age" in
      ''|*[!0-9]*) beacon_age="" ;;
    esac
  fi

  # The supervision model belongs to the INSPECTED home, not to whoever ran
  # this command. An explicit FM_SUPERVISION_MODEL still wins; otherwise
  # classify the lock-holder pid through fm-harness.sh ancestry. No holder,
  # or a walk that names nothing, is honest unknown - never the caller's
  # own harness, and never a durable per-home model record.
  local resolved_model harness anc
  resolved_model=${FM_SUPERVISION_MODEL:-}
  if [ -z "$resolved_model" ] && [ "$lock_state" = held ] && [ -n "$lock_pid" ]; then
    anc=$("$SELF_DIR/fm-harness.sh" ancestry "$lock_pid" 2>/dev/null || true)
    harness=${anc#* }
    case "$harness" in
      claude|cursor) resolved_model=autoarm ;;
      pi|pi-signed|omp) resolved_model=extension ;;
      '') ;;
      unknown) ;;
      *) resolved_model=persistent ;;
    esac
  fi
  if [ -z "$resolved_model" ]; then
    consumer_state=unknown
    consumer_reason="supervision-model-unknown-for-home"
  elif ! command -v fm_watcher_supervision_verdict >/dev/null 2>&1; then
    consumer_state=unknown
    consumer_reason="no-wake-lib"
  else
    FM_SUPERVISION_MODEL=$resolved_model \
      fm_watcher_supervision_verdict "$STATE" "$watch" "${FM_GUARD_GRACE:-300}" \
        "$FM_HOME" "$FM_ROOT"
    if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
      consumer_state=healthy
      consumer_reason="supervised"
    elif [ "$FM_WATCHER_VERDICT_REASON" = no-watcher ]; then
      consumer_state=unknown
      consumer_reason="no-watcher"
    elif [ -e "$beat" ]; then
      consumer_state=down
      consumer_reason="stale-beacon"
    else
      consumer_state=down
      consumer_reason="no-beacon"
    fi
  fi

  case "$lock_state:$consumer_state" in
    held:healthy) can_receive=true ;;
    free:*|stale:*|*:down) can_receive=false ;;
    *) can_receive=unknown ;;
  esac

  python3 - "$lock_state" "$lock_pid" "$live_harness" \
    "$consumer_state" "$consumer_reason" "$beacon_age" \
    "$posture" "$can_receive" "$observed" "$FM_HOME" <<'PY'
import json, sys
from pathlib import Path
(lock_state, lock_pid, live_harness, consumer_state, consumer_reason,
 beacon_age, posture, can_receive, observed, home) = sys.argv[1:11]
live_val = True if live_harness == "true" else False if live_harness == "false" else None
recv = True if can_receive == "true" else False if can_receive == "false" else "unknown"
pid_val = int(lock_pid) if lock_pid.isdigit() else None
age_val = int(beacon_age) if beacon_age.isdigit() else None
home_label = "/".join(Path(home).parts[-2:]) if home else home
json.dump({
    "schema": "fm-primary-ready.v1",
    "home": home_label,
    "observed_at": observed,
    "lock": {
        "state": lock_state,
        "pid": pid_val,
        "live_harness": live_val,
    },
    "wake_consumer": {
        "state": consumer_state,
        "reason": consumer_reason or None,
        "beacon_age_seconds": age_val,
    },
    "posture": {"state": posture},
    "can_receive": recv,
}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
}

# ---------------------------------------------------------------- phone channel

phone_channel_configured() {
  [ -e "$CONFIG/phone-channel" ]
}

# The effective voice-authority setting. Anything but a readable `confirm` is
# `hold`: a typo or an unreadable file must never widen what voice may approve.
voice_authority() {
  local path="$CONFIG/voice-authority" value
  if [ ! -e "$path" ]; then
    printf 'hold\n'
    return 0
  fi
  if [ ! -r "$path" ]; then
    printf 'fm-inbox: %s is unreadable; voice approvals are held for the keyboard\n' "$path" >&2
    printf 'hold\n'
    return 0
  fi
  value=$(read_setting voice-authority)
  case "$value" in
    hold|confirm) printf '%s\n' "$value" ;;
    *)
      printf "fm-inbox: %s holds '%s', which is neither hold nor confirm; voice approvals are held for the keyboard\n" \
        "$path" "$value" >&2
      printf 'hold\n'
      ;;
  esac
}

# Phone updates are on while the away record exists with the phone as its
# reach channel; bin/fm-afk-contract.sh is the one reader of that record.
phone_updates_on() {
  local reach
  phone_channel_configured || return 1
  reach=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SELF_DIR/fm-afk-contract.sh" field reach_channels 2>/dev/null) || return 1
  [ "$reach" = phone ]
}

# A spoken confirmation is a note whose whole text, ignoring case, spaces, and
# punctuation, is the word "confirm".
voice_is_confirmation() {  # <body>
  local word
  word=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -d '[:space:][:punct:]')
  [ "$word" = confirm ]
}

# Append one entry to the voice window. The caller holds VOICE_LOCK; the copy
# is replaced by rename, so a reader never sees a partial window.
voice_window_append() {  # <kind> <ref> <flag>
  local tmp
  tmp=$(mktemp "$INBOX/.voice-window.XXXXXX") || return 1
  if { [ ! -f "$VOICE_WINDOW" ] || cat "$VOICE_WINDOW"; } >"$tmp" \
    && printf '%s\t%s\t%s\t%s\n' "$1" "$(date +%s)" "$2" "$3" >>"$tmp" \
    && mv "$tmp" "$VOICE_WINDOW"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Record a voice note in the voice window, once. The marker is written after
# the entry, so a crash between them costs a duplicate entry, never a missing one.
voice_window_note() {  # <note-id> <body>
  local id=$1 body=$2 confirm=0 status=0
  [ -f "$VOICE_NOTED/$id" ] && return 0
  load_wake_lib || return 1
  mkdir -p "$INBOX" "$VOICE_NOTED" || return 1
  fm_lock_acquire_wait "$VOICE_LOCK" || return 1
  if [ ! -f "$VOICE_NOTED/$id" ]; then
    voice_is_confirmation "$body" && confirm=1
    if voice_window_append voice "$id" "$confirm"; then
      : >"$VOICE_NOTED/$id" || status=1
    else
      status=1
    fi
  fi
  fm_lock_release "$VOICE_LOCK"
  return "$status"
}

# A read-back only matters inside an open window, where a following "confirm"
# note can answer it; it records the one action that confirm may authorize.
voice_window_readback() {  # <update-id> <action>
  local status=0
  load_wake_lib || return 1
  fm_lock_acquire_wait "$VOICE_LOCK" || return 1
  if [ -f "$VOICE_WINDOW" ]; then
    voice_window_append readback "$1" "$2" || status=1
  fi
  fm_lock_release "$VOICE_LOCK"
  return "$status"
}

# Read the voice window into VOICE_WINDOW_OPEN, VOICE_WINDOW_PENDING (voice
# notes of the window still waiting in the inbox), VOICE_WINDOW_LATEST, and
# VOICE_WINDOW_CONFIRMED with VOICE_WINDOW_CONFIRMED_ACTION (the last two
# entries are a read-back of that action and then a "confirm" note; a `spent`
# entry after them ends the confirmation). An unreadable window, or an entry
# this version does not know, reads as an open window with no confirmation.
voice_window_scan() {
  local kind at ref flag prev="" prev_flag="" last="" last_flag=""
  VOICE_WINDOW_OPEN=0
  VOICE_WINDOW_PENDING=""
  VOICE_WINDOW_LATEST=""
  VOICE_WINDOW_CONFIRMED=0
  VOICE_WINDOW_CONFIRMED_ACTION=""
  [ -e "$VOICE_WINDOW" ] || return 0
  if [ ! -f "$VOICE_WINDOW" ] || [ ! -r "$VOICE_WINDOW" ]; then
    VOICE_WINDOW_OPEN=1
    return 0
  fi
  while IFS=$'\t' read -r kind at ref flag || [ -n "$kind" ]; do
    case "$kind:$at" in
      voice:*[!0-9]*|voice:|readback:*[!0-9]*|readback:|spent:*[!0-9]*|spent:) kind=damaged ;;
    esac
    case "$kind" in
      voice)
        VOICE_WINDOW_OPEN=1
        VOICE_WINDOW_LATEST=$ref
        if valid_note_id "$ref" && [ -f "$INBOX/$ref.note" ]; then
          case " $VOICE_WINDOW_PENDING " in
            *" $ref "*) ;;
            *) VOICE_WINDOW_PENDING="${VOICE_WINDOW_PENDING:+$VOICE_WINDOW_PENDING }$ref" ;;
          esac
        fi
        ;;
      readback|spent) ;;
      *) VOICE_WINDOW_OPEN=1; kind=damaged ;;
    esac
    prev=$last
    prev_flag=$last_flag
    last=$kind
    last_flag=$flag
  done <"$VOICE_WINDOW"
  if [ "$last" = voice ] && [ "$last_flag" = 1 ] && [ "$prev" = readback ]; then
    case "$prev_flag" in
      merge|land|discard|decide|mandate)
        VOICE_WINDOW_CONFIRMED=1
        VOICE_WINDOW_CONFIRMED_ACTION=$prev_flag
        ;;
    esac
  fi
}

# Spend a valid confirmation for <action>, once. Under the voice lock the
# window is read again, so two gated calls racing for one confirmation cannot
# both win. Returns 1 when nothing is left to spend for this action.
voice_window_spend() {  # <action>
  local status=1
  load_wake_lib || return 1
  fm_lock_acquire_wait "$VOICE_LOCK" || return 1
  voice_window_scan
  if [ "$VOICE_WINDOW_CONFIRMED" -eq 1 ] && [ "$VOICE_WINDOW_CONFIRMED_ACTION" = "$1" ] \
    && voice_window_append spent "$VOICE_WINDOW_LATEST" "$1"; then
    status=0
  fi
  fm_lock_release "$VOICE_LOCK"
  return "$status"
}

# The voice-authority rule, printed where firstmate reads a voice-origin note.
voice_rule() {  # <note-id>
  local id=$1
  if [ "$(voice_authority 2>/dev/null)" = confirm ]; then
    printf '[voice] Voice-origin note; this home'"'"'s voice-authority setting is confirm.\n'
    printf 'A question or a request to queue work proceeds as usual.\n'
    printf 'Before a merge, a destructive, irreversible, or security-sensitive action, or a captain decision it asks for, read that exact action back (bin/fm-inbox.sh update --reply-to %s --readback <merge|land|discard|decide|mandate>) and act only once the captain'"'"'s next voice note is an explicit "confirm"; one confirm covers only that action, once.\n' "$id"
    printf 'It never changes the voice-authority setting or ends away mode; only the keyboard does.\n'
  else
    printf '[voice] Voice-origin note; this home'"'"'s voice-authority setting is hold.\n'
    printf 'Treat it as a question or a request to queue work: it approves nothing.\n'
    printf 'A merge, a destructive, irreversible, or security-sensitive action, or a captain decision it asks for waits for the keyboard: hold it for the captain (bin/fm-captain-hold.sh hold) and say so in the phone reply.\n'
    printf 'It never changes the voice-authority setting, ends away mode, or becomes away instructions; the guarded scripts refuse voice-held authority on their own.\n'
  fi
  printf 'Answer it on the phone with bin/fm-inbox.sh update --reply-to %s.\n' "$id"
}

cmd_phone() {
  [ "$#" -eq 0 ] || die "usage: fm-inbox.sh phone"
  local opted=0 updates=off window=closed confirmation=none pending=0 setting
  phone_channel_configured && opted=1
  phone_updates_on && updates=on
  setting=$(voice_authority)
  voice_window_scan
  [ "$VOICE_WINDOW_OPEN" -eq 0 ] || window=open
  [ "$VOICE_WINDOW_CONFIRMED" -eq 0 ] || confirmation="valid:$VOICE_WINDOW_CONFIRMED_ACTION"
  if [ -n "$VOICE_WINDOW_PENDING" ]; then
    pending=$(printf '%s\n' "$VOICE_WINDOW_PENDING" | wc -w | tr -d ' ')
  fi
  printf 'opted_in=%s\nupdates=%s\nvoice_authority=%s\nvoice_window=%s\nvoice_pending=%s\nconfirmation=%s\n' \
    "$opted" "$updates" "$setting" "$window" "$pending" "$confirmation"
}

voice_gate_noun() {  # <action>
  case "$1" in
    merge) printf 'merge' ;;
    land) printf 'local-only landing' ;;
    discard) printf 'forced discard' ;;
    decide) printf 'captain decision' ;;
    mandate) printf 'away instructions' ;;
  esac
}

cmd_voice_gate() {
  local action=${1:-} standing=0 check=0 setting noun first
  local usage="usage: fm-inbox.sh voice-gate <merge|land|discard|decide|mandate> [--standing] [--check]"
  case "$action" in
    merge|land|discard|decide|mandate) shift ;;
    *) printf 'fm-inbox: %s\n' "$usage" >&2; exit 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --standing) standing=1; shift ;;
      --check) check=1; shift ;;
      *) printf 'fm-inbox: %s\n' "$usage" >&2; exit 2 ;;
    esac
  done
  voice_window_scan
  [ "$VOICE_WINDOW_OPEN" -eq 1 ] || return 0
  setting=$(voice_authority)
  noun=$(voice_gate_noun "$action")
  if [ "$setting" = confirm ] && [ "$VOICE_WINDOW_CONFIRMED" -eq 1 ]; then
    if [ "$VOICE_WINDOW_CONFIRMED_ACTION" = "$action" ] \
      && { [ "$check" -eq 1 ] || voice_window_spend "$action"; }; then
      return 0
    fi
    if [ "$VOICE_WINDOW_CONFIRMED_ACTION" != "$action" ]; then
      printf 'fm-inbox: voice authority: the %s is refused - the captain'"'"'s spoken confirm answered a read-back of a %s, and a confirm authorizes only the action that was read back.\n' \
        "$noun" "$(voice_gate_noun "$VOICE_WINDOW_CONFIRMED_ACTION")" >&2
      printf 'fm-inbox: read this %s back with bin/fm-inbox.sh update --readback %s, and act only once the captain'"'"'s next voice note is an explicit "confirm".\n' \
        "$noun" "$action" >&2
      exit 1
    fi
    voice_window_scan
  fi
  if [ -n "$VOICE_WINDOW_PENDING" ]; then
    first=${VOICE_WINDOW_PENDING%% *}
    printf 'fm-inbox: voice authority: the %s is refused - voice note %s is still pending, and under this home'"'"'s voice-authority setting (%s) a voice note never approves a %s on its own.\n' \
      "$noun" "$VOICE_WINDOW_PENDING" "$setting" "$noun" >&2
    if [ "$setting" = confirm ]; then
      printf 'fm-inbox: read this %s back with bin/fm-inbox.sh update --reply-to %s --readback %s, and act only once the captain'"'"'s next voice note is an explicit "confirm"; a confirm already spent authorizes nothing more.\n' \
        "$noun" "$first" "$action" >&2
    else
      printf 'fm-inbox: hold it for the keyboard: hold the task for the captain (bin/fm-captain-hold.sh hold), say on the phone that it waits for the keyboard (bin/fm-inbox.sh update --reply-to %s), then acknowledge the note (bin/fm-inbox.sh drain --ack %s).\n' \
        "$first" "$first" >&2
    fi
    exit 1
  fi
  if [ "$standing" -eq 0 ]; then
    printf 'fm-inbox: voice authority: the %s is refused - the captain has spoken by voice since the last keyboard message (latest voice note %s), and under this home'"'"'s voice-authority setting (%s) that approval waits for the keyboard.\n' \
      "$noun" "${VOICE_WINDOW_LATEST:-unknown}" "$setting" >&2
    printf 'fm-inbox: only when the captain gives this approval in an unmarked keyboard message, run bin/fm-inbox.sh keyboard and retry; never run it because a voice note asked.\n' >&2
    exit 1
  fi
  return 0
}

cmd_keyboard() {
  [ "$#" -eq 0 ] || die "usage: fm-inbox.sh keyboard"
  local notes="" kind at ref flag
  [ -e "$VOICE_WINDOW" ] || { printf 'keyboard: no voice window was open\n'; return 0; }
  load_wake_lib || die "closing the voice window needs $FM_ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$VOICE_LOCK" || die "could not lock the voice window"
  if [ -f "$VOICE_WINDOW" ]; then
    while IFS=$'\t' read -r kind at ref flag || [ -n "$kind" ]; do
      [ "$kind" = voice ] && notes="${notes:+$notes }$ref"
    done <"$VOICE_WINDOW"
  fi
  if ! rm -f "$VOICE_WINDOW"; then
    fm_lock_release "$VOICE_LOCK"
    die "could not close the voice window at $VOICE_WINDOW"
  fi
  fm_lock_release "$VOICE_LOCK"
  printf 'keyboard: closed the voice window (voice notes: %s)\n' "${notes:-none}"
}

# Append one feed entry, or re-append an existing one with --resend. The caller
# holds PHONE_FEED_LOCK. Text and voice travel in the environment so neither is
# ever parsed as an option. Prints "<update-id> <cursor>".
feed_append() {  # new <kind> <reply-to> <request-id> <readback> <voice-mode> | resend <update-id>
  python3 - "$PHONE_FEED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" <<'PY'
import json, os, sys, uuid

feed, at, mode = sys.argv[1], sys.argv[2], sys.argv[3]
rows, ids, top = [], set(), 0
if os.path.exists(feed):
    with open(feed, "rb") as handle:
        for raw in handle:
            try:
                row = json.loads(raw.decode("utf-8"))
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            rows.append(row)
            if isinstance(row.get("update_id"), str):
                ids.add(row["update_id"])
            if isinstance(row.get("seq"), int) and row["seq"] > top:
                top = row["seq"]

if mode == "resend":
    target = sys.argv[4]
    found = [r for r in rows if r.get("update_id") == target]
    if not found:
        sys.exit(3)
    entry = dict(found[-1])
    entry["resend"] = True
else:
    kind, reply_to, request_id, readback, voice_mode = sys.argv[4:9]
    update_id = "fmu-" + uuid.uuid4().hex
    while update_id in ids:
        update_id = "fmu-" + uuid.uuid4().hex
    entry = {
        "schema": "fm-phone-update.v1",
        "update_id": update_id,
        "kind": kind,
        "reply_to": reply_to or None,
        "reply_to_request_id": request_id or None,
        "readback": readback == "1",
        "resend": False,
        "text": os.environ["FM_INBOX_UPDATE_TEXT"],
        "voice": None if voice_mode == "none" else os.environ["FM_INBOX_UPDATE_VOICE"],
    }
entry["seq"] = top + 1
entry["at"] = at

line = (json.dumps(entry, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
fd = os.open(feed, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
try:
    # A torn tail from a crash must not swallow this entry into its line.
    if os.fstat(fd).st_size > 0:
        with open(feed, "rb") as handle:
            handle.seek(-1, os.SEEK_END)
            if handle.read(1) != b"\n":
                line = b"\n" + line
    os.write(fd, line)
    os.fsync(fd)
finally:
    os.close(fd)
print("%s %012d" % (entry["update_id"], entry["seq"]))
PY
}

emit_update_json() {  # <outcome> <update-id> <cursor> [reason]
  python3 - "$@" <<'PY'
import json, sys
outcome, update_id, cursor = sys.argv[1:4]
reason = sys.argv[4] if len(sys.argv) > 4 else ""
json.dump({
    "schema": "fm-inbox-update.v1",
    "outcome": outcome,
    "update_id": update_id or None,
    "cursor": cursor or None,
    "reason": reason or None,
}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY
}

cmd_update() {
  local reply_to="" readback=0 readback_action="" voice="" voice_mode="" json=0 resend="" text path
  local kind request_id="" result rc=0 update_id cursor
  local usage="usage: fm-inbox.sh update [--reply-to <note-id> [--readback <merge|land|discard|decide|mandate>]] (--voice <text> | --voice-file <path> | --no-voice) [--json] [--] <text>... (or: update ... -), or update --resend <update-id> [--json]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reply-to)
        [ "$#" -ge 2 ] || die "$usage"
        reply_to=$2
        shift 2
        ;;
      --readback)
        [ "$#" -ge 2 ] || die "$usage"
        case "$2" in
          merge|land|discard|decide|mandate) ;;
          *) die "--readback names the one action the read-back covers: merge, land, discard, decide, or mandate" ;;
        esac
        readback=1
        readback_action=$2
        shift 2
        ;;
      --voice)
        [ "$#" -ge 2 ] || die "$usage"
        [ -z "$voice_mode" ] || die "give exactly one of --voice, --voice-file, or --no-voice"
        voice=$2
        voice_mode=text
        shift 2
        ;;
      --voice-file)
        [ "$#" -ge 2 ] || die "$usage"
        [ -z "$voice_mode" ] || die "give exactly one of --voice, --voice-file, or --no-voice"
        [ -r "$2" ] || die "cannot read voice file: $2"
        voice=$(cat "$2"; printf .)
        voice=${voice%.}
        voice_mode=text
        shift 2
        ;;
      --no-voice)
        [ -z "$voice_mode" ] || die "give exactly one of --voice, --voice-file, or --no-voice"
        voice_mode=none
        shift
        ;;
      --resend)
        [ "$#" -ge 2 ] || die "$usage"
        resend=$2
        shift 2
        ;;
      --json) json=1; shift ;;
      --) shift; break ;;
      -h|--help) die "$usage" ;;
      *) break ;;
    esac
  done
  phone_channel_configured \
    || die "no phone channel is configured in this home: the captain opts in by creating $CONFIG/phone-channel"
  need_python
  mkdir -p "$INBOX"
  load_wake_lib || die "the phone feed needs $FM_ROOT/bin/fm-wake-lib.sh"

  if [ -n "$resend" ]; then
    [ "$#" -eq 0 ] && [ -z "$reply_to" ] && [ "$readback" -eq 0 ] && [ -z "$voice_mode" ] \
      || die "--resend re-sends a recorded update exactly as it was; give no text or other options"
    fm_lock_acquire_wait "$PHONE_FEED_LOCK" || die "could not lock the phone feed"
    result=$(feed_append resend "$resend") || rc=$?
    fm_lock_release "$PHONE_FEED_LOCK"
    [ "$rc" -ne 3 ] || die "no update $resend is recorded in the phone feed"
    [ "$rc" -eq 0 ] || die "could not re-send update $resend"
    update_id=${result%% *}
    cursor=${result#* }
    if [ "$json" -eq 1 ]; then
      emit_update_json resent "$update_id" "$cursor"
    else
      printf 'resent %s\n' "$update_id"
    fi
    return 0
  fi

  if [ "$#" -eq 0 ]; then
    die "$usage"
  elif [ "$1" = "-" ]; then
    [ "$#" -eq 1 ] || die "$usage"
    text=$(cat; printf .)
    text=${text%.}
  else
    text="$*"
  fi
  [ -n "${text//[[:space:]]/}" ] || die "refusing to send an empty update"
  [ -n "$voice_mode" ] \
    || die "give the voice-friendly version with --voice or --voice-file (or --no-voice to leave it to the hub's rewrite)"
  if [ "$voice_mode" = text ]; then
    [ -n "${voice//[[:space:]]/}" ] || die "the voice-friendly version is empty; pass --no-voice instead"
  fi

  if [ -n "$reply_to" ]; then
    valid_note_id "$reply_to" || die "invalid note id: $reply_to"
    path=$(note_path "$reply_to") || die "no such note: $reply_to"
    note_is_voice "$path" || die "note $reply_to is not a voice-origin note, so it has no phone to answer"
    request_id=$(sed -n '/^--$/q;s/^request_id=//p' "$path" | head -n 1)
    kind=reply
  else
    [ "$readback" -eq 0 ] || die "--readback reads an action back to a voice note, so it needs --reply-to"
    kind=escalation
    if ! phone_updates_on; then
      if [ "$json" -eq 1 ]; then
        emit_update_json skipped "" "" "phone updates are off"
      else
        printf 'skipped: phone updates are off (they are on only while away with the phone as the reach channel); nothing was sent\n'
      fi
      return 0
    fi
  fi

  fm_lock_acquire_wait "$PHONE_FEED_LOCK" || die "could not lock the phone feed"
  result=$(FM_INBOX_UPDATE_TEXT="$text" FM_INBOX_UPDATE_VOICE="$voice" \
    feed_append new "$kind" "$reply_to" "$request_id" "$readback" "$voice_mode") || rc=$?
  fm_lock_release "$PHONE_FEED_LOCK"
  [ "$rc" -eq 0 ] || die "could not write the update to the phone feed"
  update_id=${result%% *}
  cursor=${result#* }
  if [ "$readback" -eq 1 ] && ! voice_window_readback "$update_id" "$readback_action"; then
    die "update $update_id was sent, but its read-back was not recorded, so a spoken confirm cannot answer it; read the action back again"
  fi
  if [ "$json" -eq 1 ]; then
    emit_update_json created "$update_id" "$cursor"
  else
    printf 'update %s\n' "$update_id"
  fi
}

cmd_feed() {
  local after="" all=0
  local usage="usage: fm-inbox.sh feed [--after <cursor>] [--all]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --after)
        [ "$#" -ge 2 ] || die "$usage"
        after=$2
        shift 2
        ;;
      --all) all=1; shift ;;
      *) die "$usage" ;;
    esac
  done
  need_python
  python3 - "$PHONE_FEED" "$FEED_BOUND" "$all" "$after" "$FM_HOME" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys
from pathlib import Path

feed, bound, all_rows, after, home, generated = sys.argv[1:7]
bound = int(bound)
rows, malformed = [], 0
if os.path.exists(feed):
    with open(feed, "rb") as handle:
        for raw in handle:
            if not raw.strip():
                continue
            try:
                row = json.loads(raw.decode("utf-8"))
            except ValueError:
                malformed += 1
                continue
            if not isinstance(row, dict) or not isinstance(row.get("seq"), int) \
                    or not isinstance(row.get("update_id"), str):
                malformed += 1
                continue
            row["cursor"] = "%012d" % row["seq"]
            rows.append(row)
rows.sort(key=lambda r: r["seq"])
if after:
    rows = [r for r in rows if r["cursor"] > after]
omitted = []
if all_rows != "1" and len(rows) > bound:
    omitted.append({
        "surface": "updates omitted by bound: %d" % (len(rows) - bound),
        "reveal": "pass --all, or read on with --after the returned cursor",
    })
    rows = rows[:bound]
if malformed:
    omitted.append({
        "surface": "malformed feed lines: %d" % malformed,
        "reveal": "inspect %s" % feed,
    })
updates = []
for r in rows:
    updates.append({k: r.get(k) for k in (
        "update_id", "cursor", "at", "kind", "reply_to", "reply_to_request_id",
        "readback", "resend", "text", "voice")})
json.dump({
    "schema": "fm-inbox-feed.v1",
    "home": "/".join(Path(home).parts[-2:]) if home else home,
    "generated": generated,
    "updates": updates,
    "cursor": updates[-1]["cursor"] if updates else (after or ""),
    "omitted": omitted,
}, sys.stdout, separators=(",", ":"), ensure_ascii=False)
sys.stdout.write("\n")
PY
}

# ---------------------------------------------------------------- say

cmd_say() {
  # Before the tool checks, so an unconfigured home is told what to configure
  # rather than what to install for a call it is not yet allowed to make.
  need_stt_model
  need aws
  need python3
  need base64

  local src wav raw transcript
  raw=$(mktemp /tmp/fm-inbox-audio-XXXXXX)
  wav=$(mktemp /tmp/fm-inbox-wav-XXXXXX.wav)
  # shellcheck disable=SC2064
  trap "rm -f '$raw' '$wav' '$wav.json'" EXIT

  if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
    src=$1
    [ -r "$src" ] || die "cannot read audio file: $src"
    cat "$src" >"$raw"
  else
    cat >"$raw"
  fi
  [ -s "$raw" ] || die "no audio received on stdin"

  # Accept a real WAV as-is; wrap headerless 16kHz mono s16le PCM if that is
  # what arrived. Anything else is rejected rather than silently mistranscribed.
  python3 - "$raw" "$wav" <<'PY'
import sys, wave
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
if data[:4] == b'RIFF':
    open(dst, 'wb').write(data)
    sys.stderr.write("fm-inbox: input is WAV, passing through\n")
elif data[:4] in (b'OggS', b'fLaC') or data[:3] == b'ID3':
    sys.exit("fm-inbox: got Ogg/FLAC/MP3; re-encode to WAV first")
else:
    if len(data) % 2:
        data = data[:-1]
    w = wave.open(dst, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(data); w.close()
    sys.stderr.write("fm-inbox: input looked like raw PCM, wrapped as 16kHz mono WAV\n")
PY

  local secs
  secs=$(python3 -c "
import wave,sys
w=wave.open('$wav'); print(round(w.getnframes()/w.getframerate(),2))")
  printf 'fm-inbox: %ss of audio, transcribing with %s in %s\n' "$secs" "$STT_MODEL" "$REGION" >&2

  python3 - "$wav" "$wav.json" <<'PY'
import base64, json, sys
b = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
json.dump([{"role": "user", "content": [
    {"audio": {"format": "wav", "source": {"bytes": b}}},
    {"text": "Transcribe the speech exactly. Output only the transcript, nothing else."},
]}], open(sys.argv[2], 'w'))
PY

  transcript=$(aws_call bedrock-runtime converse \
    --model-id "$STT_MODEL" \
    --messages "file://$wav.json" \
    --inference-config '{"maxTokens":600,"temperature":0}' \
    --query 'output.message.content[0].text' --output text) \
    || die "transcription failed"

  [ -n "${transcript//[[:space:]]/}" ] || die "transcription came back empty"
  printf 'fm-inbox: heard: %s\n' "$transcript" >&2
  queue_note voice "$transcript" "transcript_model=$STT_MODEL
audio_seconds=$secs"
}

# ---------------------------------------------------------------- status

cmd_status() {
  local pending=0
  [ -d "$INBOX" ] && pending=$(find "$INBOX" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')

  printf '=== firstmate status (read-only, no wake sent) ===\n'
  printf 'home     %s\n' "$FM_HOME"
  printf 'time     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'inbox    %s note(s) waiting for firstmate\n' "$pending"

  if [ -f "$DATA/backlog.md" ]; then
    printf '\n--- in flight ---\n'
    awk '/^## In flight/{f=1;next} /^## /{f=0} f && /^- \[/{print}' \
      "$DATA/backlog.md" | sed 's/^- \[ \] /  /' | cut -c1-150
  else
    printf '\n(no backlog at %s)\n' "$DATA/backlog.md"
  fi

  local any=0
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || break
    if [ "$any" -eq 0 ]; then printf '\n--- workers ---\n'; any=1; fi
    local id kind mode last
    id=$(basename "$m" .meta)
    kind=$(sed -n 's/^kind=//p' "$m" | head -1)
    mode=$(sed -n 's/^mode=//p' "$m" | head -1)
    last=""
    [ -f "$STATE/$id.status" ] && last=$(tail -1 "$STATE/$id.status" 2>/dev/null | cut -c1-100)
    printf '  %-42s %-6s %-10s %s\n' "$id" "${kind:-?}" "${mode:--}" "${last:-(no events yet)}"
  done
  [ "$any" -eq 1 ] || printf '\n(no workers on deck)\n'

  printf '\nNote: the last event line is history, not current state.\n'
}

# ---------------------------------------------------------------- ask

cmd_ask() {
  [ "$#" -gt 0 ] || die "usage: fm-inbox.sh ask <question>..."
  need_ask_model
  need aws
  need python3
  local q="$*" msg
  msg=$(mktemp /tmp/fm-inbox-ask-XXXXXX.json)
  # shellcheck disable=SC2064
  trap "rm -f '$msg'" EXIT

  Q="$q" python3 - "$msg" <<'PY'
import json, os, sys
json.dump([{"role": "user", "content": [{"text": os.environ["Q"]}]}],
          open(sys.argv[1], 'w'))
PY

  aws_call bedrock-runtime converse \
    --model-id "$ASK_MODEL" \
    --messages "file://$msg" \
    --system '[{"text":"You are a terse engineering assistant answering a side question. Be direct and concrete. No preamble. If you are not sure, say so."}]' \
    --inference-config '{"maxTokens":700,"temperature":0.2}' \
    --query 'output.message.content[0].text' --output text \
    || die "ask failed"
}

# ---------------------------------------------------------------- list / drain

cmd_list() {
  [ -d "$INBOX" ] || { printf '(inbox empty)\n'; return 0; }
  local any=0
  for f in "$INBOX"/*.note; do
    [ -e "$f" ] || break
    any=1
    printf '%s\n' "$(basename "$f" .note)"
    if note_is_voice "$f"; then
      voice_rule "$(basename "$f" .note)" | sed 's/^/  /'
    fi
    sed -n '/^--$/,$p' "$f" | tail -n +2 | sed 's/^/    /'
  done
  [ "$any" -eq 1 ] || printf '(inbox empty)\n'
}

cmd_drain() {
  if [ "${1:-}" = "--ack" ]; then
    shift
    [ "$#" -gt 0 ] || die "usage: fm-inbox.sh drain --ack <id>..."
    mkdir -p "$INBOX/handled"
    local id
    for id in "$@"; do
      if [ -f "$INBOX/$id.note" ]; then
        mv "$INBOX/$id.note" "$INBOX/handled/$id.note"
        printf 'acked %s\n' "$id"
      else
        printf 'already-acked %s\n' "$id"
      fi
    done
    return 0
  fi
  cmd_list
  printf '\nAck with: fm-inbox.sh drain --ack <id>...\n'
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  note)     shift; cmd_note "$@" ;;
  announce) shift; cmd_announce "$@" ;;
  reply)    shift; cmd_reply "$@" ;;
  receipts) shift; cmd_receipts "$@" ;;
  ready)    shift; cmd_ready "$@" ;;
  say)      shift; cmd_say "$@" ;;
  status)   shift; cmd_status ;;
  ask)      shift; cmd_ask "$@" ;;
  list)     shift; cmd_list ;;
  drain)    shift; cmd_drain "$@" ;;
  phone)    shift; cmd_phone "$@" ;;
  voice-gate) shift; cmd_voice_gate "$@" ;;
  keyboard) shift; cmd_keyboard "$@" ;;
  update)   shift; cmd_update "$@" ;;
  feed)     shift; cmd_feed "$@" ;;
  ''|-h|--help|help)
    # The whole header block, found rather than counted: everything after the
    # shebang up to the first line that is not a comment. A fixed line range
    # silently truncates this help the next time the header grows, and the last
    # thing to fall off the end is the PRIVACY paragraph, which is the one place
    # a new operator is told which subcommands send anything off this host.
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
