# TuningForkMidi

MIDI ports for [TuningFork](https://hex.pm/packages/tuning_fork) — play a score or a live
pattern out to a synth or a DAW, and play a keyboard into a stage.

`tuning_fork` itself is pure Elixir and needs none of this. Add this package only to reach a
MIDI device; without it, everything else still works, including writing a `.mid` file with
`TuningFork.Midi.write!/3`.

## Setup

```elixir
{:tuning_fork, "~> 0.1"},
{:tuning_fork_midi, "~> 0.1"}
```

Building needs a C compiler, and on Linux the ALSA headers (`libasound2-dev`).

## Playing out

```elixir
alias TuningFork.Midi.{Out, Port}

{:ok, [{index, name} | _rest]} = Port.outputs()
{:ok, port} = Port.open_output(index)
{:ok, playing} = Out.play(port, score, channel: 1)

Out.stop(playing)
```

A note becomes a note-on and a note-off; nothing is synthesised here, so whatever is listening
makes the sound. Pitch becomes the nearest semitone, gain becomes velocity, and how long the
voice sounds becomes the gap between the two messages. Every message is timed against one
monotonic clock reading taken at the start, so a long piece does not drift.

`Out.stop/1` sends every note off and lifts the sustain, so nothing is left ringing. A player
whose caller dies does the same.

`Out.messages/2` gives the same messages as `{seconds, bytes}` without a device, which is what
to look at when something plays wrong.

## Playing a live pattern out

```elixir
import TuningFork.Pattern, only: [stack: 1]
import TuningFork.Pattern.Control

{:ok, live} = Out.pattern(port, stack([s("bd*4, hh*8"), n("0 4 7") |> scale("c:minor")]), cps: 0.5, clock: true)
Out.update_pattern(live, s("bd*2"))
Out.pattern_cps(live, 0.75)
Out.stop(live)
```

The player walks the pattern on a wall clock, a fraction of a second ahead, and sends each
onset's note on and off at its time. Pitched values go on `:channel`; drum names from the
kit (`bd`, `sn`, `hh`, `cp`, `rd` …) go on channel 10 as General MIDI percussion; a value
with neither is skipped. `update_pattern/3` swaps at the next cycle line, or `at: :now`.
With `clock: true` the player sends MIDI start, 24 clock pulses a beat at four beats to the
cycle, and stop, so a DAW can follow it. `Out.pattern_messages/4` is the same translation
for a window of cycles, without a device.

## A port of your own

With no MIDI hardware and no loopback bus, open a virtual one. Other applications see it in
their own lists and can be pointed at it:

```elixir
{:ok, port} = Port.open_virtual_output("tuning_fork")
```

That is the way to drive a DAW or a soft synth from a laptop with nothing plugged in. Windows
has no virtual ports and answers `{:error, :no_backend}`; a loopback driver is the way there.

## Reading in

```elixir
{:ok, [{index, _name} | _rest]} = Port.inputs()
{:ok, port} = Port.open_input(index, self())
:ok = Port.listen(port)

receive do
  {:midi_in, ^port, bytes, monotonic_nanoseconds} -> handle(bytes)
end
```

One complete message per send, delivered from the backend's own thread. A port whose owner
dies is closed and reclaimed rather than left open with nobody reading it.
`TuningFork.Midi.Port.open_virtual_input/2` is the same thing under a name of your own, for
other applications to send into. `TuningFork.Midi.Message.parse/1` turns the bytes into
events: `{:note_on, channel, note, velocity}`, `{:control, channel, controller, value}`,
`{:bend, channel, amount}` and the rest.

## Playing a keyboard

```elixir
{:ok, _stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
{:ok, _listener} = TuningFork.Midi.In.start_link(port: 0, voice: "gm_piano")
```

`TuningFork.Midi.In` opens an input and plays it on a stage: each key held under its own
note until it is let go, the sustain pedal holding released keys until it comes up. The
voice is a sound name (`"gm_piano"`, `"sawtooth"`, a sample bank name), a map of controls as
`TuningFork.Kit.voice/3` takes, or a function of note and velocity returning a
`TuningFork.Voice`. `to: pid` passes every event on as `{:midi, event}` for an application
that wants the controls and program changes too, and `stage: nil` does only that. Without a
`:port`, it plays whatever `{:midi_in, port, bytes, time}` messages are sent to it.

## Both directions, watched

```elixir
{:ok, midi} = TuningFork.Midi.Monitor.start_link(voice: "gm_piano")
:ok = TuningFork.Midi.Monitor.subscribe(midi)
:ok = TuningFork.Midi.Monitor.open_input(midi, 0)
:ok = TuningFork.Midi.Monitor.open_output(midi, {:virtual, "TuningFork"})
:ok = TuningFork.Midi.Monitor.play(midi, pattern, cps: 0.5, clock: true)
:ok = TuningFork.Midi.Monitor.tap(midi, 60)
TuningFork.Midi.Monitor.state(midi)
```

`TuningFork.Midi.Monitor` is what a front end sits on: one process that opens an input and
plays it on a stage, opens an output and plays a pattern or a single tapped note out of it,
and reports every event of either direction to subscribers as
`{:midi_monitor, monitor, :in | :out, event, monotonic_nanoseconds}`. `state/1` is the
keys held on the input, the notes sounding on the output, the pedal, the wheel, the last
value of each controller and the last sixty-four events. `Out.play/3` and `Out.pattern/3`
take `to: pid` on their own to report what they send, as `{:midi_out, player, bytes, at}`.
The **TF MIDI** cell in `tuning_fork_kino` and `mix tuning_fork.midi` in
`tuning_fork_drafter` are both this monitor with a key strip on it.

## Messages

`TuningFork.Midi.Message` builds the bytes: `note_on/3`, `note_off/3`, `control/3`,
`program/2`, `bend/2`, `hush/1`. Channels are 1 to 16 as everybody counts them. Notes and
velocities are clamped rather than wrapped, so a velocity worked out from a gain over 1.0 is
loud rather than quiet.

## Without a device

Every function answers `{:error, reason}` rather than raising, so a program that runs both
with and without MIDI hardware does not have to branch. `TuningFork.Midi.Port.available?/0`
says whether the NIF loaded at all.

## What this is built on

[minimidio](https://github.com/octetta/minimidio) by Joseph Stewart, MIT, vendored at
`c_src/minimidio.h`. It is the single-file C library that speaks CoreMIDI, ALSA, WinMM and
Web MIDI; this package is the NIF over it.

The inbound path follows [erlsci/midiio](https://github.com/erlsci/midiio) (Apache-2.0), which
worked out the lifecycle a callback from a non-BEAM thread needs: keep the resource for as
long as a callback might fire, build the message in a fresh process-independent environment,
send it with a `NULL` caller env because the backend thread is not a scheduler, and monitor
the owner so an abandoned port is reclaimed. Thanks to that project for doing it first.

## Files, rather than devices

`TuningFork.Midi.encode/2` and `write!/3` in core turn a score into a Standard MIDI File, and
`read!/1` with `to_score/2` reads one back. That path is pure Elixir and needs no device and
none of this package.

## Examples

```
mix run examples/pattern_out.exs   # a live pattern out of a virtual port, with MIDI clock
mix run examples/keyboard.exs      # the first input played on a stage, as a piano
```
