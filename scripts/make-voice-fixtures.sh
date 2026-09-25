#!/bin/zsh
# Generates the spoken questions `--voice-bench` streams into both voice stacks.
#
# Why synthetic speech: the comparison needs the SAME audio for every run of
# both stacks, and a human cannot say one sentence forty times identically.
# `say` is on every Mac, so the fixtures are reproducible without a microphone.
#
# Why 16 kHz mono linear16: it is the one format both Deepgram (encoding
# linear16, sample_rate 16000) and the Gemini Live API (audio/pcm;rate=16000)
# accept natively, so neither stack pays for a resample the other does not.
#
# Why ALSO 24 kHz, in voice-fixtures-24k/: the OpenAI Realtime API takes
# audio/pcm at 24 kHz only. Resampling once, here and offline, keeps a resample
# off every stack's clock; the bench pairs each 24 kHz clip to its 16 kHz one by
# name and refuses the run if a pair is missing. The first 24 kHz set
# (2026-09-23) was converted from the committed 16 kHz WAVs, not re-spoken, so
# all three stacks hear the same utterance (it carries no content above 8 kHz);
# a regeneration derives both rates from the same `say` AIFF instead.
#
# The committed .wav files are the fixtures, and a clip whose 16 kHz and 24 kHz
# files both exist is SKIPPED: a different default system voice would change
# their length, and every measurement already taken is tied to them. Delete a
# pair to regenerate it. 06-13 (2026-09-25) are the menu-verb probe's
# (`--voice-tool-probe-menus`): two native apps and two non-native ones; 14-16
# are adversarial — no word shared with the menu item they mean. 18 names an app
# ambiguously ("code": VS Code and another installed app), so its gold is a question.
set -e

FIXTURE_DIRECTORY="${0:A:h}/voice-fixtures"
FIXTURE_24K_DIRECTORY="${0:A:h}/voice-fixtures-24k"
SCRATCH_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$SCRATCH_DIRECTORY"' EXIT
mkdir -p "$FIXTURE_DIRECTORY" "$FIXTURE_24K_DIRECTORY"

# name:question — the name orders the clips, so they sort as they were written.
questions=(
  "01-what-app:what app am i looking at right now"
  "02-wallpaper:how do i change my wallpaper"
  "03-export-button:where is the export button"
  "04-error-meaning:what does this error mean"
  "05-open-settings:open system settings for me"
  "06-finder-list-view:switch finder to list view"
  "07-finder-icon-view:switch finder to icon view"
  "08-finder-path-bar:show the path bar in finder"
  "09-finder-new-window:open a new finder window"
  "10-textedit-bring-up:bring up textedit"
  "11-textedit-new-document:new textedit document"
  "12-chrome-new-window:open a new window in chrome"
  "13-cursor-new-window:open a new window in cursor"
  "14-finder-hide-left-panel:hide the left panel in finder"
  "15-finder-rows:make finder show everything in rows"
  "16-finder-path-thing:put finder's toolbar path thing on"
  "17-cursor-editor-new-window:open a new window in the cursor code editor"
  "18-code-new-window:open a new window in code"
)

for entry in $questions; do
  name=${entry%%:*}
  question=${entry#*:}
  if [[ -f "$FIXTURE_DIRECTORY/$name.wav" && -f "$FIXTURE_24K_DIRECTORY/$name.wav" ]]; then
    echo "kept $name (exists)"
    continue
  fi
  say -o "$SCRATCH_DIRECTORY/$name.aiff" "$question"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$SCRATCH_DIRECTORY/$name.aiff" "$FIXTURE_DIRECTORY/$name.wav"
  afconvert -f WAVE -d LEI16@24000 -c 1 "$SCRATCH_DIRECTORY/$name.aiff" "$FIXTURE_24K_DIRECTORY/$name.wav"
  echo "$FIXTURE_DIRECTORY/$name.wav (+ 24 kHz copy)  <- \"$question\""
done
