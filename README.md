# Dictate

A personal, Wispr-style dictation app for the Mac menu bar.

**Hold Right Option ⌥ → talk → let go.** Whisper turns your speech into text on this Mac,
Claude (or a local model) cleans it up, and the result is pasted wherever your cursor is.

## How it works

1. **Speech to text:** Whisper large-v3-turbo through whisper.cpp, running on this Mac's GPU.
   Your audio never leaves the computer. The model loads when you start talking and is freed
   after 5 idle minutes.
2. **Cleanup:** removes fillers ("um", "uh"), applies self-corrections ("Tuesday, no wait,
   Wednesday" becomes "Wednesday"), drops repeated thoughts, and fixes punctuation.
   - **Claude** (default): Opus 5.5 at low effort. Haiku 5.5 is faster and cheaper (menu → Cleanup).
     Only the *text* is sent to Anthropic, never audio. Uses the Keychain item `anthropic-api-key`.
   - **Local (Ollama):** fully private. Requires installing Ollama and running `ollama pull gemma3:4b`.
   - **None:** pastes Whisper's raw text.
3. **Paste:** clipboard plus ⌘V into the frontmost app; your previous clipboard is restored.

## Call notes

Click 🎤 → **Start Call Notes** when a Zoom / Teams / Meet / Slack huddle starts, and
**Stop & Write Call Notes** when it ends. Dictate records two tracks, your mic ("Me") and
everything the Mac plays ("Them"), so the transcript knows who said what.
After the call:

1. Voice detection finds the speech, and Whisper transcribes each stretch on this Mac (audio never leaves).
2. Claude (Opus 5.5 by default, or Sonnet 5.5) writes the notes: Summary, Key Points, Decisions,
   Action Items, and Follow-ups. Choose **Transcript only** to keep a call 100% private.
3. A Markdown file opens with the notes and the full transcript, saved to **Documents/Call Notes**
   (change it under Call Notes Settings → Choose Notes Folder).

The first time, macOS asks for **Screen & System Audio Recording** permission (that's how it hears the other side;
nothing on screen is recorded). Audio is kept in `~/Library/Application Support/Dictate/calls/`.
Headphones give the cleanest transcript; on speakers, Dictate filters out the echo.
Always tell people you're recording.

## Menu bar

- 🎤 idle · 🔴 listening · 🔵 cleaning up
- **Copy Last Dictation:** in case a paste landed in the wrong place
- **Dictation Key:** Right Option, Right Command, or Fn/Globe
- **Edit Vocabulary:** names to spell right (ClickNNY, Covenant Church, Geoff…)
- **Open Dictation History:** every dictation (raw and cleaned), stored only on this Mac

## Files

| What | Where |
|---|---|
| Source code (this folder) | `webit365/apps/dictation` (Dropbox) |
| Installed app | `~/Applications/Dictate.app` |
| Speech model, Whisper framework | `~/Library/Application Support/Dictate/` (local, not synced) |
| Vocabulary, history | `~/Library/Application Support/Dictate/` |
| Build output | `~/Library/Caches/Dictate-build/` |

## Share with the team / install on another Mac

```bash
./package.sh   # builds, signs, and writes release/Dictate-<version>.zip + "How to install Dictate.md"
```

`release/` is in the Webit365 Dropbox, so teammates install from there (see INSTALL.md). On a new Mac
the app downloads its speech models on first launch and asks for an Anthropic API key, so no Terminal is needed.
Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` before packaging an update.
Always package on the Mac that holds the "Dictate Local Signing" certificate, so updates keep everyone's permissions.

## Rebuild

```bash
./setup.sh   # first time on a new Mac: downloads the Whisper framework + model
./build.sh   # compiles, installs to ~/Applications, and relaunches
```

Builds are signed with a private certificate, **Dictate Local Signing**, kept in the login keychain,
so permissions survive rebuilds. Without that certificate (e.g. on a new Mac), build.sh falls back to
ad-hoc signing, and macOS will ask you to re-approve Accessibility after each rebuild.

Test the pipelines without the microphone:

```bash
~/Applications/Dictate.app/Contents/MacOS/Dictate --test some-audio-file.aiff
~/Applications/Dictate.app/Contents/MacOS/Dictate --test-call folder-with-me.caf-and-them.caf
```
