# TuningFork

Sound synthesised on the BEAM. A sound is described — a waveform, a pitch, an envelope, a
filter — and a recording, when one is wanted, is a voice like any other.

Pure Elixir, no dependencies. It compiles and runs anywhere the BEAM does: a slim release
image, Livebook, CI, a machine with no sound card and no C compiler.

## Installing

```elixir
def deps do
  [
    {:tuning_fork, "~> 0.1"},
    {:tuning_fork_speaker, "~> 0.1"},
    {:tuning_fork_midi, "~> 0.1"},
    {:tuning_fork_samples, "~> 0.1"}
  ]
end
```

Only the first is needed. `tuning_fork_speaker` plays through this machine's sound device
and builds a small C library; `tuning_fork_midi` opens MIDI devices; `tuning_fork_samples`
registers Sonic Pi's recordings by name. Livebook cells are in `tuning_fork_kino`, and
terminal front ends in `tuning_fork_drafter`.

## First sounds

Render a bar to a WAV file:

```elixir
import TuningFork.Part
alias TuningFork.{Score, Voice, Wav}

pcm =
  part(bpm: 112, synth: Voice.new(shape: :saw, cutoff: 0.2))
  |> play(:d2, 1)
  |> play(:a2, 1)
  |> then(&Score.from_parts([&1], beats: 2))
  |> Score.render(44_100)

Wav.write!("bar.wav", pcm, rate: 44_100)
```

Play a pattern live through the speaker (with `tuning_fork_speaker` installed; a stage
whose sink will not open plays silently rather than failing):

```elixir
import TuningFork.Pattern.Control

{:ok, stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
TuningFork.Stage.start_pattern(stage, s("bd*4, hh*8") |> gain(0.8), cps: 0.5)
```

The scripts in `examples/` do each of these end to end and run with
`mix run examples/render_wav.exs`: a score to a WAV, a pattern to a WAV, a Strudel piece,
a Sonic Pi buffer, a MIDI file written and read back, and a live stage.

## Writing something

A `Part` is one line of music, written by moving a cursor through it rather than by counting
into it. `Score` mixes parts and renders the result to PCM.

```elixir
import TuningFork.Part

bass =
  part(bpm: 112, synth: soft_bass, pan: -0.3)
  |> play(:d2, 1.5)
  |> play(:d2, 1.5)
  |> play(:a2, 0.5)
  |> play(:d3, 0.5)

pcm =
  [bass, arpeggio, drums]
  |> TuningFork.Score.from_parts(beats: 64)
  |> TuningFork.Score.render(44_100)
```

That `pcm` is signed 16-bit little-endian, interleaved stereo, and loops without a seam: a
note whose tail runs past the end is wrapped back to the start, so the loop point is
inaudible rather than a click.

## Writing it the Sonic Pi way

The same music can be written in Sonic Pi's words. `use TuningFork.SonicPi` brings them in
alongside `Part`'s:

```elixir
use TuningFork.SonicPi

live_loop :haunted do
  sample :perc_bell, rate: rrand(-1.5, 1.5)
  sleep rrand(0.1, 2)
end

live_loop :acid do
  use_synth :tb303
  with_fx :reverb, mix: 0.3 do
    times 16 do
      play choose(chord(:e3, :minor)), release: 0.1, cutoff: rrand_i(50, 90), res: 0.9
      sleep 0.125
    end
  end
end
```

Every `live_loop` runs on the stage registered as `TuningFork.Stage`, worked out again each
time round; evaluating it again swaps it in when it next comes round. Outside a loop, with
that stage running, `play` and `sample` sound at once and `sleep` waits, so a cell or a script
plays as it is read; `hush()` stops everything. A whole buffer of source can also be read,
played or rendered as one:

```elixir
{:ok, buffer} = TuningFork.SonicPi.run(source)      # top-level code once, loops for ever
TuningFork.SonicPi.play_buffer(source, stage)
pcm = TuningFork.SonicPi.render(source, 44_100, 16.0)
```

| | |
| --- | --- |
| Notes | `play :e3` `play 52` `play 440.0` `play chord(:e3, :m7)` `play_pattern_timed` `synth :fm, note: :c3` |
| Time | `sleep 0.5` `use_bpm 120` `with_bpm` `density 2 do … end` `at [1, 2], [:a, :b], fn arg -> … end` |
| Sound | `use_synth :prophet` `use_synth_defaults` `use_transpose` — every Sonic Pi synth name, `TuningFork.SonicPi.synth_names/0` |
| Recordings | `sample :bd_haus, rate: 0.5, start: 0.25, finish: 0.5, beat_stretch: 2` `sample_duration` `use_sample_bpm` `sample_names(:ambi)` |
| Effects | `with_fx :echo, phase: 0.25 do … end` — `TuningFork.SonicPi.fx_names/0`; `control node, mix: 0.9` for what follows |
| Chance | `rrand` `rrand_i` `rand` `choose` `one_in` `dice` `shuffle` `pick` `use_random_seed` `with_random_seed` |
| Counting | `tick` `look` `tick(list)` `tick(:name)` `tick_reset` `tick_set` `ring` `ring_at` `knit` `line` `range` `spread` `bools` `mirror` `stretch` |
| Threads | `in_thread do … end` `live_loop :name, sync: :other` `cue :go` `sync :go` `stop` |
| Notes and scales | `chord` `chord_degree` `scale` `note` `degree` `octs` `midi_to_hz` `hz_to_midi` |

`play` returns a handle: `control handle, note: :c5, note_slide: 2` bends the note from
that moment, and `with_fx(:reverb, [mix: 0.1], fn room -> … control(room, mix: 0.9) … end)`
changes an effect for what comes after. `sync :name` waits for a loop to have come round with
`cue :name` — every `live_loop` cues its own name — and until then the waiting loop stays
silent. Sonic Pi's own example pieces run as written, with Ruby's `8.times do |i|` spelt
`times 8, fn i -> … end` and `notes.tick` spelt `tick(notes)`.

## Writing it the Strudel way

A piece from strudel.cc plays as written. `TuningFork.Strudel` reads the JavaScript and
turns each voice into one of this library's chains:

```elixir
js = """
setcps(.75)
let chords = chord("<Bbm9 Fm9>/4").dict('ireal')
stack(
  s("bd").struct("<[x*<1 2> [~@3 x]] x>").bank('crate'),
  chords.offset(-1).voicing().s("gm_epiano1:1").room(.5),
  n("<0!3 1*2>").set(chords).mode("root:g2").voicing().s("gm_acoustic_bass")
).late("[0 .01]*4").size(4)
"""

{:ok, pattern} = TuningFork.Strudel.pattern(js)
{:ok, rows} = TuningFork.Strudel.to_rows(js)
```

`chains/1` gives `{first_line, last_line, source}` per voice, and `to_rows/1` the same as
lines to paste into a buffer:

    s("bd") |> struct("<[x*<1 2> [~@3 x]] x>") |> bank("crate") |> late("[0 .01]*4") |> size(4)
    chord("<Bbm9 Fm9>/4") |> dict("ireal") |> offset(-1) |> voicing() |> s("gm_epiano1:1") |> room(0.5) |> late("[0 .01]*4") |> size(4)

What it reads: `$:` and `_$:` rows, or the last expression; `let` variables; method chains,
`stack`/`cat`/`seq`, arrow functions, bare transformers as arguments (`rarely(ply("2"))`,
`every(4, rev)`), signals with `.range()`, a string with a method (`"<0 1>/16".early(.5)`),
`setcps`/`setcpm`, and `samples('github:user/repo')`, which fetches the repo's
`strudel.json` and registers every name in `TuningFork.Sample.Bank`, reading each file from
the network on first play and keeping it under `$XDG_CACHE_HOME/tuning_fork/samples`.
Strudel's spellings map onto this library's — `sound`→`s`, `sz`→`size`, `legato`→`clip`,
`hurry`→`fast`, camelCase→snake_case — and a word neither has is refused by name and line
rather than played wrong. `hush()` and object literals are not read.

The front ends detect it: paste a Strudel piece into `mix tuning_fork.live` or the notebook
cell and `TuningFork.Session` translates it, hanging any error on the line it came from and
taking the tempo from `setcps`.

The words that came with it work in this library's own spelling too:

| | |
| --- | --- |
| `chord("<Bbm9 Fm9>/4") \|> dict("ireal") \|> voicing()` | Strudel's chord dictionaries (`ireal`, `ireal-ext`, `lefthand`, `triads`, `guidetones`, `legacy`) voiced by the same rules, with `anchor`, `mode` (`"root:g2"`), `offset` and `n` choosing which note |
| `n("0 2") \|> set(chords) \|> voicing()` | `set/2` merges one pattern's controls onto another's structure |
| `s("bd") \|> struct("x ~ x*2")`, `\|> mask("<0 1>/16")` | structure from, and gating by, another pattern |
| `\|> late("[0 .01]*4")`, `\|> fast("<1 2>")`, `\|> clip(rand() \|> range(0.4, 0.8))` | time words take patterns |
| `\|> bank("crate")` | prefixes every sound, so `bd` plays `crate_bd` |
| `s("gm_epiano1:1")`, `s("gm_acoustic_bass")` | Strudel's soundfonts, fetched and decoded on first use; `TuningFork.Gm` synth voices until they arrive or where they cannot |
| `s("bd sd hh cp")`, `s("piano").note("c4")`, `bank("tr808")` | the sample sets strudel.cc loads before any piece — its drum kit, the drum machines, the piano, VCSL, mridangam — registered the first time a piece is read, files fetched as they play |
| `s("sd:<2 3>")`, `s("rd:<1!3 2>*2")`, `x*<1 2>`, `.01` | the mini-notation takes a pattern after `:`, after `*` and `/`, and numbers with no leading zero |

Recordings in MP3, OGG or AAC — the soundfonts and the piano are MP3 — are decoded through
`afconvert` (macOS) or `ffmpeg` when one is installed; without either, `gm_*` names fall back
to synthesised voices and such recordings are skipped. The reverb is Freeverb, `size` in
seconds as Strudel counts it.

Every control takes a string as mini-notation — `room("<0 .2>")` reads 0 on one cycle and
0.2 on the next — and a control given a pattern cuts each event where the pattern changes
inside it, so `chord("Bbm9") |> n("0 ~ 2 ~") |> voicing() |> segment(4)` is the melody Strudel
plays rather than a chord.

## Recordings

`TuningFork.Sample.load!/2` reads a WAV (8-, 16-, 24- or 32-bit, integer or float) or a
FLAC — `TuningFork.Flac` is a pure-Elixir decoder — and the result is a voice like any
other:

```elixir
bell = Sample.load!("bell.flac", root: :a4)
part(bpm: 96, synth: Voice.new(sample: bell)) |> play(:e5, 1)
```

`TuningFork.Sample.Bank` holds recordings by name, read from disk on first use, so a name
plays wherever a drum name does — `Kit.voice("bell", 0.25)`, `s("bell*4")` in a pattern,
`sample :bell` in a loop. The `tuning_fork_samples` package registers Sonic Pi's 206 CC0
recordings — `bd_haus`, `perc_bell`, `loop_amen`, `ambi_choir` and the rest — when it starts.

## Where the sound goes

A `TuningFork.Sink` is the output backend, and none of them are privileged:

| Sink | What it does | Where it lives |
| --- | --- | --- |
| `Sink.Silent` | Discards everything. The default | here |
| `Sink.Collect` | Sends each chunk to a process | here |
| `Sink.Buffer` | Keeps every chunk in an agent, for rendering a live stage | here |
| `Sink.Pulse` | Pipes PCM into `pacat` toward a PulseAudio or PipeWire server, local or through an ssh tunnel | here |
| `Sink.Speaker` | Plays through the machine | `tuning_fork_speaker` |

`TuningFork.Sink.configured/0` is the one the application environment names, or `Silent`.

Anything with `open/1`, `write/2` and `close/1` will do — a websocket to a browser, a file, a
socket to another machine. Playback through this machine's speaker is a separate package
because it is the only part that needs a C compiler; nothing else in TuningFork depends on
it, and `TuningFork.available?/0` reports whether it is there.

For a browser — Phoenix, LiveView, Livebook — there is usually no sink at all. Render the
score to PCM and hand the bytes over.

## Mono and stereo

Stereo by default. A voice carries a `:pan` from `-1.0` hard left to `1.0` hard right, and a
part carries one that its notes are measured from.

Voices are synthesised in mono and panned as they are placed, because a panned sound is the
same signal at two levels rather than two signals. Two notes alike but for where they sit
share one render, so panning a repeated figure across the field costs nothing extra.

Pass `channels: 1` to `Score.render/3` or `Stage.start_link/1` for mono, which is close to
half the time and exactly half the bytes. The saving is not in synthesis — that is mono
either way — but in the mixing, windowing and effects downstream of it.

```elixir
TuningFork.Score.render(score, 44_100, channels: 1)
```

## Modulation

A `TuningFork.Curve` is a value that moves over the length of a note — breakpoints read by
interpolation. Pitch bends, filter sweeps and volume swells are all the same mechanism:

```elixir
|> play(:e4, 1.0, bend: 2)                                   # up a tone across the note
|> play(:e4, 1.0, curves: %{gain: Curve.linear(0.2, 1.0)})   # a swell
```

Curves are **data on the voice**, not commands against a sounding one. That is what lets the
same bend be drawn in an editor, imported from a MIDI file, emitted as source, and rendered
identically by both renderers below. A voice with no curves costs exactly what it did before
they existed — the check is made once per note, not once per sample.

## Layers under everything

A stage loops a *set* of layers beneath what is played on it — `Stage.layers/3` — each a PCM
buffer at its own gain, read from one playhead. The set can be replaced at the next bar
boundary (`at: {:bar, frames}`) with a cross-fade (`fade_ms:`), and `Stage.layer_gains/2`
changes the mix at once. `Stage.bed/2` is the same set with one layer.

## Two renderers, one score

The same `Score` plays two ways, and they agree sample for sample.

**Offline** — `Score.render/3` builds the whole buffer. It loops without a seam, folds an
effect's tail back over the loop point, and caches a repeated note. Use it for a piece that
is finished.

**Live** — `TuningFork.Transport` walks the score in time, handing out notes as they come
due, and `TuningFork.Voice.Live` advances a sounding voice a block at a time so it can be
changed while it sounds. Use it for a piece still being written.

```elixir
TuningFork.Stage.start_score(stage, score, loop: true)
TuningFork.Stage.update_score(stage, edited)   # heard from the next chunk, nothing re-rendered
```

The transport is clocked by the stage's chunk pull — the same pull that feeds the sink — so
its position is exactly the audio that has been written. No timer, no drift. A note lands on
its own sample inside a block rather than at the block edge.

What live cannot do is the offline tricks: it never knows where the loop ends until it gets
there, so no seam folding and no cross-seam reverb tail. That difference is deliberate, and
it is the only one — a voice rendered block by block is bit-identical to the same voice
rendered whole, at any block size. A part's own effects are heard live too: each layer of a
score runs through its own `TuningFork.Fx.Live` chain as it sounds.

## Effects

On a part (`fx:`), a stage (`fx:`), or a buffer (`Fx.apply/4`):

| Effect | Options |
| --- | --- |
| `echo` | `delay` seconds, `feedback`, `mix` |
| `reverb` | `room`, `damp`, `mix` |
| `drive` | `amount` |
| `level` | `amp` |
| `lowpass` `highpass` `bandpass` | `hz`, `q` |
| `slicer` | `phase` seconds, `pulse_width`, `amp_min`, `amp_max`, `wave` |
| `tremolo` | `phase`, `depth` |
| `wobble` | `phase`, `cutoff_min`, `cutoff_max`, `q`, `wave` |
| `crush` | `bits`, `hold` or `sample_rate` |
| `compressor` | `threshold`, `slope_above`, `slope_below`, `clamp_time`, `relax_time` |
| `pan` `panslicer` | `pan`; `phase`, `pan_min`, `pan_max`, `wave` |
| `flanger` | `phase`, `delay` ms, `depth` ms, `feedback`, `mix` |

`wave` is `:saw`, `:square`, `:triangle` or `:sine`.

## MIDI

```elixir
"song.mid"
|> TuningFork.Midi.read!()
|> TuningFork.Midi.to_score(synths: %{0 => lead}, drums: %{36 => kick}, default: pad)
|> TuningFork.Score.render(44_100)
```

`TuningFork.Midi.write!/3` goes the other way, turning a score into a Standard MIDI File for a
DAW to open. Both directions are pure Elixir with no dependency.

Reading is pure binary pattern matching. Tempo changes become a tempo map, note lengths
become envelopes, velocity becomes gain, and pitch bend becomes a curve. Which synth plays
what is yours to say — a MIDI program number has no reliable meaning, though `TuningFork.Gm`
gives every program a voice when nothing better is known. Control changes other than bend,
and aftertouch, are dropped. `:quantize` rounds note lengths to a grid (10 ms by default) so
a performance's hundreds of distinct lengths collapse into tens, which keeps the score's note
cache working.

Playing to a MIDI *device*, reading a keyboard into a stage, or sending a live pattern out as
MIDI needs `tuning_fork_midi`, a NIF over CoreMIDI, ALSA and WinMM.

## OSC

```elixir
{:ok, client} = TuningFork.Osc.Client.start_link(host: "127.0.0.1", port: 57_120)

TuningFork.Osc.Client.send(client, "/play", [440.0, 0.8])
{:ok, playing} = TuningFork.Osc.Out.play(client, score)
```

OSC is UDP, and `:gen_udp` comes with the runtime, so this needs no dependency and no native
code. `TuningFork.Osc.encode/2` and `decode/1` are the bytes; `Client` is the socket, sending
and — with `:listen` — receiving; `Out` plays a score as one message a note, in time.

There is no OSC convention for notes, so `Out`'s `:address` and `:shape` are how a particular
receiver is met. The default sends `/play` with frequency, gain, seconds and pan.

## Playing it live

```elixir
{:ok, _pid} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
TuningFork.play(TuningFork.Voice.new(shape: :sine, freq: 440.0))
```

A stage mixes whatever is sounding into one stream and writes it to its sink. `play/2` is a
cast and returns immediately, so a caller inside a frame never waits on audio. `Stage.bed/2`
loops a pre-rendered buffer underneath everything else, read by sample position rather than
driven by a timer, so it never drifts against what is mixed over it.

Where the sink will not open, the stage logs it and runs silently rather than failing — an
application never has to branch on whether sound is possible.

`Stage.hold/3` sounds a voice under a key until `Stage.release/3`, however long that is —
a key on a keyboard, a note-on from a MIDI port (`tuning_fork_midi` does exactly this), a
button held down in a game.

## Loops that change each time round

A named loop can be given a body — a function worked out again for every round — rather than
one score played for ever. `TuningFork.Part.Source.compile/1` gives one from source:

```elixir
{:ok, body} = TuningFork.Part.Source.compile("""
part(bpm: 120, synth: Kit.voice(%{note: "c2", shape: :saw}, 0.4))
|> play(Ring.at(~w(c2 e2 g2 a2)a, tick()), 1)
""")

{:ok, first} = body.()

Stage.start_loop(stage, :bass, first, body: body)
```

That line walks `c2 e2 g2 a2` a round at a time instead of repeating one note. Two things a
body has that a score does not:

| | |
| --- | --- |
| `TuningFork.Tick` | `tick()` steps a counter once a round and gives what it was; `look()` gives what the last tick gave. `TuningFork.Ring.at/2` wraps a list so any count is a note |
| `TuningFork.State` | `set/2` and `get/2`, for one loop to leave a value another reads |

A body is worked out during the round before the one it plays, in a process of its own, so the
audio never waits on it. One that raises leaves the loop playing what it played last.

`get/2` answers with the newest value written at or before the reading round's own time, so a
loop that has run further ahead cannot hand a slower one a value from its future, and two loops
on the same round always agree. Both counters and values live in `TuningFork.Store`, and
`Store.clear/0` puts a piece back to how it started.

`TuningFork.Transport.render_rounds/4` is the same thing offline, for rendering a board that
walks rather than playing it.

## Using it from an application

A game or any other program with a frame loop wants three things: fire a sound and carry on,
have music underneath it, and turn both down. One stage, started once, does all of it.

```elixir
{:ok, _pid} = TuningFork.Stage.start_link(voices: 12, chunk: 128)
```

Every call below is a cast, so a caller inside a frame never waits on audio, and every one is
safe when the machine has no sound card — the stage falls back to silence and keeps running.

| Call | For |
| --- | --- |
| `Stage.play/2` | A `Voice`, synthesised inside the stage |
| `Stage.play_pcm/2` | A buffer rendered earlier — the cheapest way to fire an effect |
| `Stage.bed/2` | Loop a buffer under everything else |
| `Stage.bed_gain/2`, `clear_bed/1` | How loud the bed is, and stopping it |
| `Stage.stop_all/1` | Silence what is sounding; the bed keeps going |
| `Stage.mute/2` | Silence everything, keeping levels |

The bed is read by sample position and wraps, so it never drifts against the effects mixed
over it and the loop point is where the buffer ends.

### Options that matter under load

| Option | Default | What it does |
| --- | --- | --- |
| `:voices` | 16 | Most voices at once. Past that the oldest are dropped rather than the mix breaking up |
| `:chunk` | 512 | Frames per write — latency. 512 is about 12 ms at 44100, 128 about 3 ms |
| `:limit` | 0.7 | Where peaks are rounded off. `nil` lets a loud mix clip square |
| `:fx` | none | Effects over the whole stage, as `[reverb: [room: 0.55, mix: 0.16]]` |

### Rendering once, not every time

Synthesising a piece of music takes longer than a frame. `TuningFork.Cache` keeps rendered
PCM on disk, keyed by a fingerprint of the module that renders it, so editing that module is
what invalidates it:

```elixir
pcm = Cache.fetch("game/level-3", Cache.fingerprint(Game.Music), fn ->
  Game.Music.score(3) |> Score.render(44_100)
end)

Stage.bed(pcm)
```

Storing is best-effort: a directory that cannot be written is logged and the audio returned
anyway, so a caller never handles a cache failure.

### Wrapping it

Most applications want one module between themselves and the stage: it starts the stage, maps
the game's own event atoms to voices, and keeps an effects fader and a music fader apart. That
module is the only place that knows about `TuningFork`, so the rest of the program emits
atoms and never touches audio.

## Getting audio out

`TuningFork.Wav` wraps rendered PCM in a header, which is what a browser, a file or a
Livebook cell wants:

```elixir
score |> Score.render(44_100) |> TuningFork.Wav.encode(rate: 44_100)
```

`TuningFork.Sink.Buffer` records a live stage instead, and outlives the stage that filled it.
