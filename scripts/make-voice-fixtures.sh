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
# The committed .wav files are the fixtures; re-running this script replaces
# them, and a different default system voice would change their length.
set -e

FIXTURE_DIRECTORY="${0:A:h}/voice-fixtures"
SCRATCH_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$SCRATCH_DIRECTORY"' EXIT
mkdir -p "$FIXTURE_DIRECTORY"

# name:question — the name orders the clips, so they sort as they were written.
questions=(
  "01-what-app:what app am i looking at right now"
  "02-wallpaper:how do i change my wallpaper"
  "03-export-button:where is the export button"
  "04-error-meaning:what does this error mean"
  "05-open-settings:open system settings for me"
)

for entry in $questions; do
  name=${entry%%:*}
  question=${entry#*:}
  say -o "$SCRATCH_DIRECTORY/$name.aiff" "$question"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$SCRATCH_DIRECTORY/$name.aiff" "$FIXTURE_DIRECTORY/$name.wav"
  echo "$FIXTURE_DIRECTORY/$name.wav  <- \"$question\""
done
