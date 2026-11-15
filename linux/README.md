# Wisp for Linux

The same Wisp as on the Mac (hold-to-talk dictation, styles, call notes), for **Linux Mint / Cinnamon on X11**.
Speech is turned into text on your PC with Whisper, on the NVIDIA GPU when there is one. Only text goes to Claude.

## Install (no sudo needed)

```bash
curl -fsSL https://raw.githubusercontent.com/Webit365/dictate/main/linux/install.sh | bash
```

The first install downloads about 2.5 GB of speech-engine files. Wisp then downloads its speech model
(about 1.6 GB) the first time it starts; the floating W shows **Setting up NN%**. It starts at login after that.

Needs: a 64-bit PC, Mint 21/22 (Cinnamon, X11 session), and an Anthropic API key (your own, see the main
INSTALL guide, or one from Stephen). If the installer says something is missing, it prints the one
`sudo apt install …` command that fixes it.

## Use

- **Dictate:** hold **Right Ctrl**, talk, let go. The text is typed where your cursor is.
  Change the key under the tray W → **Dictation Key** (Right Ctrl or Right Alt). PC keyboards' fn key can't be used.
- **Style:** click the floating **W** (or tray W → Style…) to pick Formal / Casual / very casual for personal
  messages, work messages, email and everything else.
- **Call notes:** click **Notes** on the floating W when a call starts, **Stop** when it ends. The notes open in a
  window about a minute later and are saved in **Documents/Call Notes** (change it under Call Notes Settings).
  Wisp records your microphone and everything your PC plays through its speakers, so **mute other audio during a
  call** (music, a scanner feed) or it ends up in the transcript. Always tell people you're recording.
- **Floating W:** drag it anywhere; right-click → Hide Floating W. Show it again from the tray menu.

## Where things are

| | |
|---|---|
| App, speech engine, model, recordings, history | `~/.local/share/wisp/` |
| Settings and vocabulary | `~/.config/wisp/` |
| API key | the desktop keyring (Passwords and Keys → "Wisp: Anthropic API key") |
| Log | `~/.local/share/wisp/wisp.log` |

**Update:** run the install command again. **Remove:** quit Wisp, then delete `~/.local/share/wisp`,
`~/.config/wisp`, `~/.local/share/applications/wisp.desktop` and `~/.config/autostart/wisp.desktop`.

## Test modes

```bash
~/.local/share/wisp/wisp-launch --check                 # GPU, model, key, audio sources
~/.local/share/wisp/wisp-launch --test clip.wav email   # transcribe + clean a recording
~/.local/share/wisp/wisp-launch --test-call folder      # folder with me.wav / them.wav → notes
```
