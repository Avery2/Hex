# Hex (Swift Fork)

**On-device voice-to-text for macOS.** Hold one key and talk — the words land where you're typing.
Double-tap it instead and Hex records hands-free, for as long as the thought takes. Nothing leaves
your Mac.

A fork of [Hex](https://github.com/kitlangton/Hex) that keeps the original Swift app and rebuilds the
part you actually look at: a recording bar at the top of the screen, the transcript appearing while
you speak, and a history that an interrupted take can still be recovered from.

## Demo

A quick walkthrough: the recording bar, live transcription, the two ways to record, and getting a
transcript back after the app was interrupted.

https://github.com/user-attachments/assets/a8248383-ebbd-47f8-8f7d-decefb8ed6dd

## Two gestures, two intentions

| Gesture | What it is for | What happens at the end |
| --- | --- | --- |
| **Hold** the hotkey, talk, let go | A quick dictation — faster than typing a sentence | Pastes and gets out of the way |
| **Double-tap** the hotkey | A session — thinking out loud, notes, a long reply | The bar stays: paste it, read it, or close it |

The default hotkey is `Option`. A locked session ends on the hotkey again, or on the bar's own
buttons.

## The recording bar

One row at the top of the screen, the same size and in the same place for the whole take: a dot, the
elapsed time, the live transcript, and Cancel / Finish.

- **It never moves and never takes your keyboard.** It is a panel that cannot become key, so reaching
  for Finish doesn't pull focus out of the app you are dictating into, and the only part of the screen
  that takes a click is the bar itself.
- **Escape does nothing.** It used to cancel a take, which meant an Escape aimed at whatever you were
  working in could throw one away. Stopping is the hotkey, or the bar's buttons.
- **Cancel keeps what you said.** The audio and transcript are stored without being pasted — one click
  from the bar's **Paste**, or `⌥⇧V` later.
- **A session's ending stays put:** `✓ Session ended · 4:12`, a spinner while the words are still
  being decoded, then **Paste** to send this take wherever you are now, a chevron that opens the whole
  transcript, and **×** to dismiss it.

## Why this fork

- **Live transcription.** The words appear while you speak, so you can see it heard you before you
  stop.
- **States that tell the truth.** "Not listening yet" and "Not hearing you" are different problems,
  and the bar says which one you have.
- **Nothing is dropped.** Audio is written durably as it arrives, the tail after your stop signal is
  captured, a recording interrupted by a crash or a quit is repaired and transcribed on the next
  launch, and a cancelled take is kept rather than deleted.
- **History with the audio.** Every transcript keeps its recording, including the ones never pasted,
  and `⌥⇧V` pastes the last one again.
- **Model choice.** Parakeet (default, multilingual, fast) or Whisper at several sizes, downloaded from
  inside the app.

## Install

Requires macOS 14 or later on Apple silicon, and Xcode 16 to build.

```sh
git clone https://github.com/Avery2/Hex.git
cd Hex
./install-fork.sh     # builds, signs and installs /Applications/Hex Debug.app, then launches it
```

`install-fork.sh` signs with your own Apple Development identity: that is what keeps Microphone,
Accessibility and Input Monitoring granted across rebuilds, since ad-hoc signing changes the app's hash
every time. Open `Hex.xcodeproj` and press Run if you'd rather work in Xcode.

GitHub releases are older than the source here while this fork is in motion — build from source to get
what is described above.

### First run

Hex asks for three permissions, and each one does a specific job:

- **Microphone** — recording.
- **Accessibility** — pasting into the frontmost app.
- **Input Monitoring** — the hotkey.

Then pick a model in Settings (Parakeet TDT v3 is a good default) and say something. The hotkey and
everything else live in Settings → Hotkey.

## Models

Downloads are curated rather than a catalogue; all run on-device on the Neural Engine or GPU.

- **Parakeet TDT v3** — default. Multilingual, fast, and the best trade of accuracy to latency here.
- **Parakeet TDT v2** — English-only, a little smaller.
- **Whisper** — Tiny, Base, Large v3 Turbo and Large v3, for when you want Whisper's behaviour or a
  different language mix.

Models live under `~/Library/Application Support/com.kitlangton.Hex/models` (Whisper) and the app's
container (Parakeet), and can be deleted or re-downloaded from Settings.

## Project layout

- `Hex/` — the app: TCA features, AppKit windows, SwiftUI views.
- `HexCore/` — the parts worth testing on their own: the hotkey state machine, recording decisions,
  durability, settings, persistence.
- `HexTests/`, `HexCore/Tests/` — tests. `cd HexCore && swift test` for the core.
- `docs/hotkey-semantics.md` — exactly what every key and click does while recording.

## Credits

Built on [Hex](https://github.com/kitlangton/Hex) by Kit Langton, whose upstream has since moved to
[Rust](https://github.com/anomalyco/hex). Transcription by
[WhisperKit](https://github.com/argmaxinc/WhisperKit) and [FluidAudio](https://github.com/FluidInference/FluidAudio);
state by [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture);
hotkeys by [Sauce](https://github.com/Clipy/Sauce); updates by
[Sparkle](https://github.com/sparkle-project/Sparkle).

MIT licensed — see [LICENSE](LICENSE).
