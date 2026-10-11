# Changelog

## [0.1.12]

### Added

* `TuningFork.Stage.layers/3` takes `from_start: true`: the new layers begin at their own
  start instead of at the playhead. `TuningFork.Stage.drop_layers/2` stops named layers
  while the rest play on (`TuningFork.Stage.Bed.drop/2`).
* `TuningFork.Mixer.fit/5`: PCM moved to another rate and channel count.
* `TuningFork.Xwma`: xWMA audio (WMA v2 packets with their seek table, as XACT wave
  banks hold it) wrapped as an `.xwma` file and decoded to PCM by the first available
  `TuningFork.Xwma.Decoder`: `TuningFork.Wma` when a package provides it, else the
  machine's `ffmpeg` (`TuningFork.Xwma.Ffmpeg`); `:xwma_decoders` sets the order.
* `TuningFork.Mus` reads DMX MUS, Doom's music format, into the same `TuningFork.Midi`
  value a MIDI file reads into, so `TuningFork.Gm.score/2` plays it.
* `TuningFork.Envelope.gated/2` and the envelope's `:gate`: the envelope played as a key
  held for so many seconds and then let go, releasing from whatever level it had reached.
* `TuningFork.Stage.play/3` takes `:key`, `:gain`, `:pan` and `:fade`: a voice played
  under a key replaces the one sounding there and plays to the end of its envelope.
  `TuningFork.Stage.hold/4` takes `:gain`, `:pan` and `:fade`.
* `TuningFork.Stage.place/3` moves what sounds under a key to a new `:gain` and `:pan`
  while it plays, spread across the next chunk; a key's placement carries over to the
  next voice sounded under it.
* `TuningFork.Stage.play_pcm/3` takes the same options: mono PCM played under a key is
  placed and moved like a voice, and `TuningFork.Stage.release/3` fades it. Held in a
  `TuningFork.Stage.Clip`.
* `TuningFork.Mixer.place/4`: a mono buffer placed in the field while its gain and pan
  move in a straight line from one `{gain, pan}` to another.

### Changed

* `TuningFork.Midi.to_score/2` holds each note's key for the note's length and lets it go
  at the end (`Envelope.gated/2`) rather than stretching the synth's decay over the note:
  a long note decays in the synth's own time and holds its sustain, and a struck voice
  dies away rather than ringing to the note's end. The default voice sounds at full level
  for as long as a note is held.
* `TuningFork.Midi.to_score/2` plays channel volume (controller 7) and expression (11) as
  General MIDI does — volume 100 and expression 127 until the file sets them — as a
  `:gain` curve when they move while a note sounds, and pan (10) as the voice's `:pan`.
  A file that never sets its volume plays at 100/127 of its former level. `:level_points`
  caps the curve's breakpoints, default 32.

### Fixed

* A voice or PCM let go under a key keeps its key while it fades, so it fades at its
  placement and `place/3` still moves it.

### Breaking changes

* None since 0.1.11. An app moving from 0.1.7 or earlier registers its SFZ instruments with `TuningFork.Sfz.register/2` (see 0.1.8).

## [0.1.11]

* Released alongside the family; no changes to this package.

## [0.1.10]

* Released alongside the family; no changes to this package.

## [0.1.9]

* Released alongside the family; no changes to this package.

## [0.1.8]

* `TuningFork.Sfz` carries no instruments of its own. The application registers the ones
  it plays with `TuningFork.Sfz.register/2` (or `register/1` for many), each with its
  source, licence, credit and what it is, or under `config :tuning_fork, :sfz` as before;
  `instruments/0` lists what is registered. The FreePats, E-Pianos, Splendid Grand and
  Karoryfer entries the library used to list are gone from it.
* `TuningFork.Sample.Fetch.settle/0` waits until every fetch and background task under way
  has finished; `TuningFork.Sample.Font.clear/0` waits for them before forgetting the
  loaded fonts.

## [0.1.7]

* Released alongside the family; no changes to this package.

## [0.1.6]

* `TuningFork.Sfz` reads an SFZ instrument into a pitched `TuningFork.Sample.Bank`: one
  velocity layer (`:velocity`, default 100), every round robin of a note, loops, and an
  optional `:keys` range. `load/2` takes a name from `instruments/0`, a
  `github:user/repo/branch/path` source, a URL or a local path; recordings are fetched as
  notes ask for them, or all at once with `prefetch: true`. The kit plays a known name as a
  sound — `s("fingerbass")` — and loads it the first time a pattern plays it.
* `TuningFork.Midi.mini/2` gives one channel of a MIDI file as Strudel mini-notation,
  `{bars, mini}`, a `[…]` of steps per bar. Options: `:channel`, `:beats_per_bar`,
  `:steps_per_beat`, `:from`, `:bars`, `:voice` (`:all`, `:lowest`, `:highest`), `:on`
  (`:steps`, `:beats`) and `:transpose`.
* `TuningFork.Stage` renders a pattern in a process of its own,
  `TuningFork.Pattern.Ahead`, a few chunks ahead of the stream. `update_pattern/3`,
  `pattern_gain/2`, `pattern_cps/2` and `hush/1` sound within those chunks; `cycle/1`
  reports how far the rendering has reached.
* `Pattern.Player.new/3` and `Stage.start_pattern/3` take `:parallel` to render the
  sounding voices on every core; default `false`.
* `Cache.fetch/4` takes `:dir` and `Cache.path/3` a directory, default `Cache.dir/0`;
  `fetch/4` removes an earlier fingerprint of the same key.
* `Sample.Bank.put/3` takes a file as `{path, opts}` with options of its own (`:loop`,
  `:gain`, `:root`), and a pitched map's note as a MIDI number, fractional when the
  recording lies between two notes. `Sample.from_pcm/2` takes `:gain`.
* `Mixer.silent?/1` says whether every sample is zero; `Mixer.mix/1` passes over silent
  buffers and pads the result to the longest one.
* `Sample.Fetch.get/1` leaves characters that are already percent-encoded as they are.
* `TuningFork.Strudel` translates string literals of any length in full.
* `TuningFork.Sink.Tcp`'s `:warm_up_ms` defaults to `0`; `:prime_frames` sets how many
  frames go at once before a warm-up, default `1024`. Its log lines are prefixed
  `tuning_fork:` like the rest of the library's.

## 0.1.5

* `TuningFork.Sink.Process` — each chunk of raw signed 16-bit PCM as a `{:pcm, binary}` message to a process, paced to real time with `:lead_ms` in flight.
* `TuningFork.Sink.Tcp` — raw signed 16-bit PCM over a TCP connection, paced to real time with `:lead_ms` in flight, connecting on the first write and again every `:retry_ms` when the far end is not there; `:warm_up_ms` gives a player that buffers while it opens its device that long before real time starts.

## 0.1.4

* `Stage.pattern_gain/2` and `Pattern.Player.gain/2` scale a pattern's whole output,
  sounding notes included; `0.0` is silence.

## 0.1.3

* A `TuningFork.Part` synth may be a function of the note — an instrument — and
  `TuningFork.Kit.instrument/4` makes one from any sound name, so a part plays a soundfont
  or a bank recording at each note.
* `Part.repeat/3` takes a string of `x` and `.` as well as a count: a pass plays on `x` and
  keeps its place silently on `.`.
* A bank the kit does not have starts `TuningFork.Strudel.defaults/1` loading, and a voice
  asked for with `wait: true` waits for it; `Strudel.defaults(wait: true)` and
  `Sample.Set.load_all/2` are the waited-for forms.
* `sd` is a snare name; mini-notation reads `-.3`.
* `Envelope.spanning/2` drops the envelope's hold, so a note asked to last `seconds` does
  — a voice with a hold, such as a soundfont's, used to ring on past it.

## 0.1.1

* `bank/2` keeps the bank name on each event; the kit plays the recording registered as
  `bank_sound` when the bank has it, and its own drum until then. Before, a name in
  `TuningFork.Kit.banks/0` never reached the recordings.
* `struct/2` keeps every note sounding at a structural step, so a voiced chord under
  `struct` sounds whole.
* `use_synth` takes a sound name — `use_synth "gm_epiano1"` — played at each note through
  the kit. `TuningFork.Kit.known?/1` says which names qualify.
* A sample file whose name has a space in it is fetched.
* A step whose edge fell a rounding error inside a query span could be reported twice;
  `Pattern.query/2` leaves such slivers out.

## 0.1.0

First release.
