# How to install Wisp

Wisp is Webit365's own dictation app, similar to Wispr Flow. Hold a key, talk, and let go: your words are
typed, cleaned up, wherever your cursor is. It also records calls and writes notes with action items.

**You need:** an Apple Silicon Mac (M1, M2, M3, M4) on macOS 14 or newer, about 1 GB of free space,
and an Anthropic API key (ask Stephen for yours).

## 1. Install

1. In Dropbox, open **webit365 → apps → dictation → release**.
2. Double-click the **Wisp zip** (for example Wisp-1.4.zip). A **Wisp** app appears next to it.
3. Drag **Wisp** into your **Applications** folder.

## 2. Open it the first time

Wisp isn't from the App Store, so macOS asks you to confirm it once:

1. In Applications, **right-click Wisp → Open**, then click **Open** again.
2. If macOS only offers "Move to Trash" or "Done": open **System Settings → Privacy & Security**,
   scroll down, and click **Open Anyway** next to the Wisp message.

A Webit365 **W** appears in your menu bar and floating at the bottom of your screen.

## 3. Finish setup (one time)

- **API key:** a Welcome box asks for your key. Paste it (it starts with `sk-ant-`) and click **Save**.
- **Speech model download:** Wisp downloads its speech model (about 575 MB). The floating W shows
  **Setting up 40%** while this happens. It takes a few minutes, and you only do it once.
- **Microphone:** click **Allow** when asked.
- **Accessibility** (needed to type for you): open **System Settings → Privacy & Security → Accessibility**,
  click **+**, choose **Wisp** from Applications, and turn it **on**.
  If dictation ever stops typing, Wisp shows a message and leaves your text on the clipboard; press ⌘V.

## 4. Use it

**Dictation:** click into any text box, **hold Right Option ⌥**, talk, and let go. The W bounces while you talk.
"Um"s and "uh"s are removed, and corrections like "Tuesday, no wait, Wednesday" become just "Wednesday".

- Prefer the **fn / 🌐 key**? Choose it in the menu-bar **W → Dictation Key**, then in
  **System Settings → Keyboard**, set **"Press 🌐 key to"** to **Do Nothing**.
- Names it gets wrong (clients, places): **W menu → Edit Vocabulary…**, one per line.
- **Style:** click the floating **W** (or W menu → **Style…**) to set how casual your text comes out in personal messages, work chats, email, and everything
  else: **Formal** (capitals + full punctuation), **Casual** (capitals, lighter punctuation, no final period), or
  **very casual** (all lowercase). Wisp picks the style from the app you're dictating into.

**Call notes:** click **Notes** on the floating W when a Zoom / Teams / Meet / Slack call starts, and **Stop** when it ends.
About a minute later a **Call Notes window** pops up with the summary, decisions, action items, and the full
transcript. Use its buttons to **Copy Notes**, **Open in Browser**, or **Show in Finder**. The notes are also saved
automatically in **Documents → Call Notes** (change the folder under **W menu → Call Notes Settings**).
To see them again later: **W menu → Show Last Call Notes**.
The first time, allow **Screen & System Audio Recording**; that's how it hears the other side. Nothing on screen is recorded.
**Always tell people you're recording.** Headphones give the cleanest transcripts.

## Privacy

- Your voice is transcribed **on your Mac**. Audio is never uploaded.
- Only the *text* is sent to Claude (Anthropic) for cleanup and notes. Anthropic doesn't train on it.
- For a sensitive call, choose **W menu → Call Notes Settings → Transcript only**; nothing leaves your Mac.
- Your dictation history and recordings stay in `~/Library/Application Support/Dictate/` on your Mac.

## Updating

When a new version shows up in the release folder: quit Wisp (**W menu → Quit**), unzip the new version,
and drag it into Applications, replacing the old one. Your settings and permissions carry over.
Coming from the older **Dictate** app? Quit it, drag **Dictate** from Applications to the Trash, then install Wisp.

## Help

- Floating W in the way? Drag it anywhere (a click on the W opens Style; a drag moves it), or right-click it → **Hide Floating Head**.
- Something not working? Click the **W in the menu bar**. Any problem is shown at the top of the menu.
- Questions: ask Stephen.
