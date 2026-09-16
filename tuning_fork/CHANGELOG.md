# Changelog

## 0.1.5

* `TuningFork.Sink.Tcp`: raw 16-bit PCM over a TCP connection, paced to real time, made on
  the first write and remade when it drops — for a player on the far end of an ssh tunnel or
  across a LAN.
* `TuningFork.Sink.Process`: the same PCM as `{:pcm, chunk}` messages to a process, paced,
  with `:lead_ms` kept in flight.

## 0.1.4

* `TuningFork.Sink.Process` — each chunk of raw signed 16-bit PCM as a `{:pcm, binary}` message to a process, paced to real time like `Sink.Tcp`; the sink for a player whose sound leaves the node on a socket of its own, such as a Phoenix channel.
* `TuningFork.Sink.Tcp` — raw signed 16-bit PCM over a TCP connection, paced to real time with `:lead_ms` in flight, connecting on the first write and again every `:retry_ms` when the far end is not there, and giving the player `:warm_up_ms` to open its device before real time starts so its start-up never becomes lag; plays into `ffplay -f s16le -ar 44100 -ch_layout stereo -i "tcp://…?listen"`, `sox` or `pacat --raw` on any OS, on the far end of an ssh tunnel.
* `Stage.pattern_gain/2` and `Pattern.Player.gain/2` scale a pattern's whole output,
  sounding notes included; `0.0` is silence.
* The README opens the tour notebook in Livebook from a badge, and names the projects this
  library owes to.

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
