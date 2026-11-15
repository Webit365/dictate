#!/bin/bash
# One-time download of the pieces that don't belong in Dropbox:
#  - whisper.cpp Mac framework (official GitHub release, ~66 MB)
#  - Whisper large-v3-turbo speech model, q5 (official Hugging Face repo, ~575 MB)
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/Dictate"
WHISPER_BUILD="b5454"   # whisper.cpp v1.9.5
mkdir -p "$SUPPORT/models" "$SUPPORT/vendor"

if [ ! -d "$SUPPORT/vendor/whisper.xcframework" ]; then
  TMP="$(mktemp -d)"
  curl -fSL -o "$TMP/xc.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_BUILD/whisper-$WHISPER_BUILD-xcframework.zip"
  unzip -q "$TMP/xc.zip" -d "$TMP"
  mv "$TMP/build-apple/whisper.xcframework" "$SUPPORT/vendor/"
  rm -rf "$TMP"
fi

MODEL="$SUPPORT/models/ggml-large-v3-turbo-q5_0.bin"
if [ ! -f "$MODEL" ]; then
  curl -fSL -o "$MODEL" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
fi
VAD="$SUPPORT/models/ggml-silero-v6.2.0.bin"
if [ ! -f "$VAD" ]; then
  curl -fSL -o "$VAD" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
fi
echo "Setup complete. Now run ./build.sh"
