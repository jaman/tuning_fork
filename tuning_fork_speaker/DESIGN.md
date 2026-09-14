# tuning_fork_speaker design

This package is only the speaker. `tuning_fork` itself is pure Elixir and needs none of it:
without this dependency everything but playback through the machine still works, including
rendering to a buffer or a file. Building it needs a C compiler, and on Linux the ALSA
headers (`libasound2-dev`).

## TuningFork.Speaker.Device

The playback device is a NIF over miniaudio. The device runs its own thread and drains a ring
buffer that `write/2` fills. PCM is interleaved signed 16-bit little-endian, `channels`
samples to a frame.

`write/2` never blocks: it copies what fits in the ring and returns how many frames that was,
leaving the rest to the caller. A ring that runs empty plays silence rather than stalling.

Every function except `available?/0` raises `ErlangError` if the NIF did not build, so
callers check `available?/0` before opening a device. Answering `available?/0` means opening
a device and closing it again, which is slow enough to be worth avoiding on a keypress, so the
answer is remembered in a persistent term for the life of the VM. A machine that gains or
loses an audio device while running keeps the answer it started with.

## TuningFork.Speaker.Keys

Reads single keypresses without waiting for Enter. `raw/0` turns off the terminal's line
buffering and echo and `cooked/0` puts them back; a caller that calls `raw/0` must call
`cooked/0` before it finishes, or it leaves the user's shell without echo.

The mode is set on `/dev/tty`, not on this process's standard input, because under `mix`
those are different handles. Where there is no terminal (a pipe, CI) every function returns
`:ok` and does nothing.

The reader started by `watch/1` is spawned unlinked: it neither keeps its owner alive nor
brings it down.

## TuningFork.Sink.Speaker

A `TuningFork.Sink` implementation driven by `TuningFork.Stage`. It requires a C compiler at
build time and an audio device at run time; `open/1` returns `{:error, :unavailable}` when
there is none. `TuningFork.available?/0` delegates to `available?/0` once this package is on
the load path.

Latency: a sound is heard behind whatever audio is already queued ahead of it. `write/2`
therefore blocks until the queue is down to `:lead` frames before adding more, holding the
delay at roughly `:lead` frames (about 12 ms at 44.1 kHz for the default of 512) whatever
rate the mixer could otherwise run at.

`:buffer` is the ring the device drains and is much larger than `:lead` (the default of 4096
frames is about 93 ms). The difference is headroom: while the writer is descheduled the device
plays on from what is already in the ring rather than gapping.

## Mix.Tasks.TuningFork.Play

Plays a MIDI file through `TuningFork.Stage`, note by note off the transport, rather than by
rendering the whole piece first. Sound starts as soon as the file is parsed however long the
piece is, and the position is driven by the same chunk pull that feeds the speaker.
`mix tuning_fork.render` performs the same conversion to a file and needs no device.

The `--gain` default of 0.2 suits sparse music; dense music wants it lower. `--reverb` is
applied to the live stream. Drum channels are guessed unless `--drums`, `--drum-channels` or
`--no-guess` (channel 10 only, as General MIDI specifies) says otherwise.
