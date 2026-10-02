#!/bin/zsh
# Speaks every scenario utterance (utterances.tsv) into the two fixture formats
# the realtime stacks take: 16 kHz mono linear16 (Gemini) and 24 kHz (OpenAI),
# from ONE `say` render so both stacks hear the same audio.
#
# Each clip gets a sidecar <id>.words holding "voice|rate|words". A clip is
# re-spoken when its sidecar differs from the current line, so changing a
# scenario's words regenerates its audio; the runner refuses a stale clip.
# The audio is git-ignored (fixtures/.gitignore): it is cheap to rebuild.
set -e

HERE="${0:A:h}"
OUT="$HERE/fixtures"
VOICE="${SCENARIO_VOICE:-Samantha}"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$OUT"

while IFS=$'\t' read -r id rate words; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  sidecar="$VOICE|$rate|$words"
  if [[ -f "$OUT/$id.wav" && -f "$OUT/$id.24k.wav" && "$(cat "$OUT/$id.words" 2>/dev/null)" == "$sidecar" ]]; then
    echo "kept $id"
    continue
  fi
  args=(-v "$VOICE" -o "$SCRATCH/$id.aiff")
  [[ "$rate" != "-" ]] && args+=(-r "$rate")
  say "${args[@]}" "$words"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$SCRATCH/$id.aiff" "$OUT/$id.wav"
  afconvert -f WAVE -d LEI16@24000 -c 1 "$SCRATCH/$id.aiff" "$OUT/$id.24k.wav"
  print -r -- "$sidecar" > "$OUT/$id.words"
  echo "spoke $id <- \"$words\""
done < "$HERE/utterances.tsv"
