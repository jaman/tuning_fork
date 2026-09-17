# TuningForkSpeaker

Plays [TuningFork](https://hex.pm/packages/tuning_fork) audio through the machine's sound device.

This is the only part of TuningFork that needs a C compiler. It is a separate package so
that `tuning_fork` itself stays pure Elixir with no dependencies — an application that
renders to a buffer, writes a WAV, or hands audio to a browser never builds any C.

```elixir
def deps do
  [
    {:tuning_fork, "~> 0.1"},
    {:tuning_fork_speaker, "~> 0.1"}
  ]
end
```

Then point a stage at it:

```elixir
{:ok, _pid} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
TuningFork.play(TuningFork.Voice.new(shape: :sine, freq: 440.0))
```

`TuningFork.available?/0` reports whether this package is present and its device opens.
Where it is not, `TuningFork.Stage` falls back to `TuningFork.Sink.Silent` rather than
failing, so an application never has to branch on it.

## Building

Needs a C compiler, and on Linux the ALSA headers (`libasound2-dev`). Audio is via
[miniaudio](https://miniaud.io), vendored in `c_src`.

## Playing a MIDI file

```
mix tuning_fork.play examples/bwv971.mid
mix tuning_fork.play loop.mid --loop --bpm 96 --drums
```

`mix help tuning_fork.play` lists the options: tempo, gain, waveform, which channels are
drums, and `--wav` to render to a file instead.

## Example

`examples/trio.exs` is drums, bass and piano written as `TuningFork.Part`s and played
through the speaker:

```
mix run examples/trio.exs
mix run examples/trio.exs --bars 4 --bpm 96
mix run examples/trio.exs --wav trio.wav
```

## Listening on a port

`TuningFork.Listener` plays raw signed 16-bit PCM arriving on a TCP port through the
speaker, one connection after another, dropping what arrives faster than it plays down
to `:max_lag_ms` — the far end of `TuningFork.Sink.Tcp` on another machine.

```
mix tuning_fork.listen --port 5000
mix tuning_fork.listen --port 5000 --ip 0.0.0.0 --max-lag 100
```
