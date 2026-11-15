# Install Wisp (instructions for Claude Code)

You are helping a Webit365 team member install **Wisp**, Webit365's private dictation and call-notes app
for Mac. Follow these steps in order, explain each one in plain language, and stop to help if one fails.

## Rules

- **Never ask for, read, or handle the Anthropic API key.** The person pastes it into Wisp's own Welcome box.
- **Don't change System Settings yourself.** Open the right settings pane and tell the person what to click.
- Run the commands yourself. Ask the person only to click things in macOS.

## 1. Check the Mac

```bash
uname -m && sw_vers -productVersion
```

Needs `arm64` (Apple Silicon) and macOS 14 or newer. If not, stop: Wisp won't run on this Mac.

## 2. Download and install the latest version

No GitHub account is needed; the download is public.

```bash
TMP=$(mktemp -d)
curl -fL --progress-bar -o "$TMP/Wisp.zip" https://github.com/Webit365/dictate/releases/latest/download/Wisp.zip
pkill -x Wisp 2>/dev/null; pkill -x Dictate 2>/dev/null
rm -rf /Applications/Dictate.app ~/Applications/Dictate.app      # the app's old name
ditto -x -k "$TMP/Wisp.zip" "$TMP/app"
rm -rf /Applications/Wisp.app
ditto "$TMP/app/Wisp.app" /Applications/Wisp.app
open /Applications/Wisp.app
```

If the download fails, the person can install from the Dropbox folder **webit365 → apps → dictation → release**
instead (unzip, drag Wisp into Applications).

If macOS says it can't verify the app, have the person go to **System Settings → Privacy & Security**,
scroll down, and click **Open Anyway** next to the Wisp message.

A red **W** appears in the menu bar and floating at the bottom of the screen.

## 3. Walk the person through setup

1. **API key:** a "Welcome to Wisp" box asks for an Anthropic API key (starts with `sk-ant-`). They paste it
   into that box and click **Save**. They can use their own key or one from Stephen. If they want their own:
   - Open https://console.anthropic.com for them (`open https://console.anthropic.com`), and have them sign up.
   - Under **Billing**, they add a card and some credits.
   - Under **API Keys**, they click **Create Key**, copy it, and paste it straight into Wisp's box. Not into this chat.

   Usage bills to their own account: a small fraction of a cent per dictation, a few cents per call for notes.
   No key yet? They can click **Skip**. Dictation still works without cleanup, and they can add a key later
   under W menu → Change Anthropic API Key.
2. **Speech model:** Wisp downloads its speech model (about 575 MB). The floating W shows "Setting up NN%".
   Wait until it finishes.
3. **Microphone:** click **Allow** when asked.
4. **Accessibility** (needed so Wisp can type for them):
   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```
   Tell them: click **+**, choose **Wisp** from Applications, and turn it on.
5. **Test it:** click into any text box, hold **Right Option ⌥**, say a sentence, and let go. The text appears,
   cleaned up.

## 4. Show them the basics

- **Dictate:** hold Right Option ⌥, talk, and let go. (They can switch to the fn/🌐 key under menu-bar W → Dictation Key.)
- **Style:** click the floating W to choose Formal, Casual, or very casual for personal messages, work
  messages, email, and everything else.
- **Call notes:** click **Notes** on the floating W when a call starts and **Stop** when it ends. The notes pop up
  in a window about a minute later. The first time, macOS asks for Screen & System Audio Recording permission,
  so Wisp can hear the other side of the call. Always tell people on the call that it's being recorded.
- **Privacy:** speech is turned into text on the Mac. Only the text goes to Claude for cleanup and notes.

Full guide: `INSTALL.md` in the repo.

## Updating later

Run step 2 again. Settings and permissions carry over.
