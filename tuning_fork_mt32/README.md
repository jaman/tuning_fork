# TuningForkMt32

Plays MIDI the way a Roland MT-32 does, through your own installation of the
[Munt](https://github.com/munt/munt) emulator. Nothing of Munt is included: this package
loads your copy when a synth is opened.

```elixir
def deps do
  [
    {:tuning_fork, "~> 0.1.12"},
    {:tuning_fork_mt32, "~> 0.1"}
  ]
end
```

## Setting it up

Set `MUNT_LOCATION` to a directory holding:

* the Munt library: `libmt32emu.dylib` (macOS), `libmt32emu.so` (Linux) or `mt32emu.dll`
  (Windows), in the directory itself or in its `lib/`, and
* the MT-32 ROMs `MT32_CONTROL.ROM` and `MT32_PCM.ROM` (or the CM-32L's
  `CM32L_CONTROL.ROM` and `CM32L_PCM.ROM`).

```sh
export MUNT_LOCATION=$HOME/munt
```

Without it, `TuningFork.Mt32.available?/0` is `false` and `open/1` returns
`{:error, :no_munt}`; play the same MIDI through `TuningFork.Gm` instead.

## Use

```elixir
if TuningFork.Mt32.available?() do
  {:ok, synth} = TuningFork.Mt32.open()
  {:ok, sample} = TuningFork.Mt32.render_midi(synth, TuningFork.Midi.read!("song.mid"))
else
  TuningFork.Gm.score(TuningFork.Midi.read!("song.mid"))
end
```

The result is a `TuningFork.Sample`: mono PCM at the synth's rate. Save it as a WAV:

```elixir
TuningFork.Wav.write!("song.wav", sample.pcm, rate: sample.rate, channels: 1)
```

Or play it through the speaker, with `tuning_fork_speaker` installed:

```elixir
{:ok, _stage} = TuningFork.Stage.start_link(sink: TuningFork.Sink.Speaker)
TuningFork.play(TuningFork.Voice.new(sample: sample))
```

`TuningFork.Mt32.render/3` takes raw messages with their times in seconds, sysex
included, for music that sends its own patches, and returns stereo PCM at the synth's
rate. `TuningFork.Mt32.close/1` stops the synth and frees it.

## Options and limits

`TuningFork.Mt32.open/1` takes:

* `:location` — the directory holding the Munt library and ROMs, default `MUNT_LOCATION`
* `:rate` — the output rate asked of Munt, default 32 000, the MT-32's own

A synth keeps its state between renders: patches sent by sysex stay until it is closed.
`render_midi/2` adds two seconds after the file's last event for notes to release;
`render/3` renders exactly the seconds asked for.

## Building

Building needs a C compiler only; Munt is found at run time.

## Licence

MIT, see `LICENSE`. Munt is not bundled: it is loaded from your own installation, under
its own licence, and the MT-32 and CM-32L ROMs are your own.
