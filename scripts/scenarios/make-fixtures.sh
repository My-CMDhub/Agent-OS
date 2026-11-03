#!/bin/zsh
# Speaks every scenario utterance (utterances.tsv) into the two fixture formats
# the realtime stacks take: 16 kHz mono linear16 (Gemini) and 24 kHz (OpenAI),
# from ONE `say` render so both stacks hear the same audio.
#
# Each clip gets a sidecar <id>.words holding "voice|rate|words". A clip is
# re-spoken when its sidecar differs from the current line, so changing a
# scenario's words regenerates its audio; the runner refuses a stale clip.
# The audio is git-ignored (fixtures/.gitignore): it is cheap to rebuild.
#
# Section K: each id has a voice and what a real room does to it, inside 250 ms before and 200 ms after (`say` is still a floor, not the owner's voice).
#   quiet: -18 dB. fast: 1.3x. noise: pink room noise, about 15 dB under the speech. tail: the last 40% mumbled, -18 dB.
set -e
typeset -A STYLE=(
  K01 "Karen:-" K02 "Daniel:-" K03 "Rishi:fast" K04 "Moira:-" K05 "Karen:quiet" K06 "Daniel:tail" K07 "Rishi:noise"
  K08 "Eddy (English (UK)):-" K09 "Karen:tail" K10 "Samantha:-" K11 "Moira:noise" K12 "Daniel:quiet" K13 "Karen:fast"
  K14 "Reed (English (UK)):-" K15 "Karen:-" K16 "Rishi:quiet" K17a "Karen:-" K17 "Karen:-" K18a "Daniel:-" K18 "Daniel:tail"
  K19a "Moira:-" K19 "Moira:noise" K20 "Karen:noise"
)

# What the room does, into $2 from $1.
degrade() {
  case "$3" in
    quiet) ffmpeg -nostdin -loglevel error -y -i "$1" -af "volume=-18dB" "$2" ;;
    fast)  ffmpeg -nostdin -loglevel error -y -i "$1" -af "atempo=1.3" "$2" ;;
    noise) local seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")
           ffmpeg -nostdin -loglevel error -y -i "$1" -f lavfi -t "$seconds" -i "anoisesrc=color=pink:amplitude=0.12:seed=7" \
             -filter_complex "[0:a]aresample=24000[s];[1:a]aresample=24000[n];[s][n]amix=inputs=2:duration=longest:normalize=0" "$2" ;;
    tail)  local seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")
           ffmpeg -nostdin -loglevel error -y -i "$1" -af "volume=eval=frame:volume='if(lt(t,$(( seconds * 0.6 ))),1,0.126)'" "$2" ;;
  esac
}

HERE="${0:A:h}"
OUT="$HERE/fixtures"
VOICE="${SCENARIO_VOICE:-Samantha}"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$OUT"

while IFS=$'\t' read -r id rate words; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  style=${STYLE[$id]:-$VOICE:-}
  voice=${style%:*}
  room=${style##*:}
  sidecar="$voice+$room|$rate|$words"
  [[ "$room" == "-" ]] && sidecar="$voice|$rate|$words"
  if [[ -f "$OUT/$id.wav" && -f "$OUT/$id.24k.wav" && "$(cat "$OUT/$id.words" 2>/dev/null)" == "$sidecar" ]]; then
    echo "kept $id"
    continue
  fi
  args=(-v "$voice" -o "$SCRATCH/$id.aiff")
  [[ "$rate" != "-" ]] && args+=(-r "$rate")
  say "${args[@]}" "$words"
  if [[ "$room" != "-" ]]; then
    degrade "$SCRATCH/$id.aiff" "$SCRATCH/$id.room.wav" "$room"
    mv "$SCRATCH/$id.room.wav" "$SCRATCH/$id.aiff"
  fi
  # A person's press comes before their first word and lets go after the last; `say` starts on sample one (Nova-3 lost "hide" and "where").
  if [[ -n "${STYLE[$id]}" ]]; then
    ffmpeg -nostdin -loglevel error -y -i "$SCRATCH/$id.aiff" -af "adelay=250:all=1,apad=pad_dur=0.2" "$SCRATCH/$id.pad.wav"
    mv "$SCRATCH/$id.pad.wav" "$SCRATCH/$id.aiff"
  fi
  afconvert -f WAVE -d LEI16@16000 -c 1 "$SCRATCH/$id.aiff" "$OUT/$id.wav"
  afconvert -f WAVE -d LEI16@24000 -c 1 "$SCRATCH/$id.aiff" "$OUT/$id.24k.wav"
  print -r -- "$sidecar" > "$OUT/$id.words"
  echo "spoke $id <- \"$words\""
done < "$HERE/utterances.tsv"
