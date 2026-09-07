# Acta

Transcribes your meetings **as they happen**, on your Mac, without the audio ever
leaving the machine. No account, no subscription, no bot joining the call.

It tells apart what you say from what everyone else says, and writes a Markdown
file you can read while the meeting is still going.

```
[09:14:22] them: So the price tooltip — per line item?
[09:14:31] you:  Per bay, because the front desk can't see the tech column.
```

---

## Why it exists

Meeting-notes tools get transcription right and privacy wrong: they ship the
audio of your conversations — with clients, with numbers, with half-made
decisions — to somebody else's server.

macOS 26 ships `SpeechAnalyzer`, speech recognition that runs **on device** and
is good. Acta is the application that was missing around it.

There is a second, less obvious reason. A meeting summary loses exactly what
matters. *What* was decided survives any summary; *why* it was decided only
exists in the raw sentence somebody said in passing. So Acta keeps the full
transcript as plain text and never tries to summarise it.

## What it does

- **Live transcription**, while the meeting is happening.
- **Two sources, kept apart**: your microphone (`you`) and the call audio (`them`).
- **Notices you joined a meeting** — Zoom, Teams, Meet, Discord — and offers to
  record from the menu bar.
- **One `.md` per meeting** in `~/Documents/Acta/meetings`. Plain text: anything
  opens it, `grep` searches it, an agent reads it.
- **Fixes proper nouns** on the way out, with a dictionary you fill in.
- **No network.** No server, no API key, no telemetry.

## How it works

```
  microphone ─────────────► SpeechTranscriber ──┐
                                                 ├──► echo filter ──► .md
  system audio ───────────► SpeechTranscriber ──┘
   (process tap)
```

### Capturing system audio

This is the hard part, and it took three attempts.

**ScreenCaptureKit** was the first and it did not work: the stream starts, the
permission is granted, a video output is registered… and it never delivers a
single audio buffer.

**A virtual driver** ([BlackHole](https://github.com/ExistentialAudio/BlackHole))
did work: build a multi-output device and read it like a microphone. But it has a
fatal flaw in practice — **it forces you to start recording before any sound
begins**, because apps already playing keep sending audio to the previous device.
And you remember to record once the meeting is already underway.

**What shipped: a CoreAudio process tap** (`AudioHardwareCreateProcessTap`,
macOS 14.4+). It taps system audio **without touching the output or the
routing**:

- you can launch it mid-call;
- the volume keys keep working;
- nothing extra to install.

The permission is the trap: on macOS, system audio lives under the **screen
recording** permission. Without it the tap is created just fine,
`AudioDeviceStart` returns `noErr`… and not one buffer arrives. It fails
silently, which is the worst way to fail — so Acta asks for it explicitly and
shows a signal meter per channel, so a dead channel is visible in the moment
instead of at read time.

### Keeping the speakers out of your channel

If you listen through speakers — most people do — your microphone also picks up
everyone else, and the `you` channel ends up duplicating the whole `them`
channel.

**The microphone is muted while the call is audible.** Crude, but it runs live,
needs no model, and does not touch the audio you are listening to. It is the
approach the open source meeting recorders actually ship.

The threshold is learned, not set. The first attempt used a fixed number that
sounded reasonable (0.012) and never fired once: a process tap delivers far
quieter samples than a microphone does, so the bar sat above everything that
channel ever produced, and a gate that never closes looks exactly like a gate
that does not work. Now the floor is tracked — falling fast through silences,
rising slowly — and the gate closes when the signal jumps 3.5× above it.

**The honest cost:** a sentence spoken *over* somebody else is lost rather than
duplicated. Turn-taking is unaffected.

#### Two approaches that were tried and dropped

**Comparing the transcripts.** The first version dropped anything from the
microphone that had already appeared on the call, using word and bigram overlap.
Every one of its failures came from the same root — it acts after the fact. It
could not judge short phrases ("A puerta o." carries one long word, so it was
never examined), it had to hold the microphone channel back several seconds so
the other side could arrive first, and every near-miss printed the same sentence
in both columns. It survives as a backstop, literal matches only.

**Apple's voice processing** (`setVoiceProcessingEnabled`). This one *works*:
measured at 97.6% less microphone energy with the same audio playing. It was
still dropped, because it assumes it is running a call and ducks everything else
so the local speaker is heard over it — quieting the meeting you are trying to
listen to. The ducking level can be lowered, not turned off: the API's own floor
is named `min`, not `none`. None of the projects that solved this problem use it,
which in hindsight was the clue.

Real echo cancellation with an aligned reference signal is what removes the
trade-off. Acta already captures the reference; what is missing is the alignment
and the model.

### Noticing the meeting

Two signals, because one is not enough:

1. **Who grabbed the microphone** — CoreAudio's process list
   (`kAudioHardwarePropertyProcessObjectList`). Strong, permission-free, no false
   positives. Works for native Zoom and Teams.
2. **What page is open** — in a Meet lobby the browser is already playing audio
   while the microphone still reads as free, so the first signal arrives too
   late. And the lobby is exactly when the prompt is useful.

A Meet tab forgotten in a background window does not trigger anything: the
browser also has to have audio going.

## Install

Requires macOS 26 (Tahoe) or later, on Apple Silicon.

```sh
git clone https://github.com/joseguzmann/acta.git
cd acta && ./build.sh
open Acta.app
```

Two things the first time:

1. In **Settings**, download the speech model for your language.
2. Accept the **screen and system audio recording** permission. Without it there
   is no call channel.

> **A trap worth knowing.** Adding a language under System Settings does **not**
> download its speech model — it has to be requested explicitly, and Acta has the
> button for it. Also, not every locale exists: Spanish is `es_CL`, `es_ES`,
> `es_MX`, `es_US`. A Mac set to `es_EC` will fail to recognise anything, without
> saying why.

## What to expect from the quality

Measured against a script, with audio playing in the background:

| Situation | Result |
|---|---|
| Turn-taking (others quiet while you talk) | The sentence comes out whole |
| You talk **over** someone | That stretch mixes and breaks |
| Proper nouns | Badly, almost always |

Proper nouns are the real weak spot: *Agents Booster* came out as "Agence busca",
*Supabase* as "supervise", *YouTrack* as "Utrak". Apple Speech takes no custom
vocabulary, so Acta corrects **on the way out** using
`~/Documents/Acta/corrections.tsv`. The engine invents a different variant every
time, so that file fills up with use.

**Do not quote a proper noun from a transcript without checking it.**

## Reading them from an agent

Acta ships an **MCP** server (`MCP/acta-mcp`, stdio, no network) with three
tools: `list_meetings`, `read_meeting` and `meeting_running`.

`read_meeting` with the id `current` returns the meeting being recorded right
now, and it can be re-read as often as needed **while the meeting is still
going** — which is the use case that motivated all of this: asking an agent about
something said two minutes ago, without leaving the call.

```json
"acta": { "type": "stdio", "command": "/path/to/acta/MCP/acta-mcp", "args": [] }
```

## Layout

| File | What it solves |
|---|---|
| `Recorder.swift` | The engine: two channels, transcription, incremental writing |
| `SystemTap.swift` | The process tap: system audio without touching the output |
| `Echo.swift` | Subtracting from the microphone what already came through the system |
| `MeetingDetector.swift` | Which processes hold the microphone, which tabs are open |
| `Library.swift` | The history, which is a folder of files |
| `Corrections.swift` | Output-side dictionary for proper nouns |
| `Audio.swift` | CoreAudio devices |
| `Views.swift`, `MainView.swift`, `ActaApp.swift` | The interface |
| `MCP/acta-mcp.swift` | MCP server over stdio |

There is deliberately no database: a meeting is a `.md` in a folder. Back it up
with `cp`, search it with `grep`, version it with git, and still read it in ten
years.

## Limitations

- **No diarisation within `them`.** Three people on the call all come out as
  `them`.
- **Without the system audio permission only the microphone is recorded** —
  which through speakers still captures everyone, but with no way to tell who
  spoke.
- **Requires macOS 26**: `SpeechAnalyzer` does not exist before it.

## License

MIT.
