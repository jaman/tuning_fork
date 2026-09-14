# tuning_fork_midi design

This package is only the MIDI ports. `tuning_fork` itself is pure Elixir and needs none of
it: without this dependency everything but playing to and reading from a MIDI device still
works, including writing a `.mid` file with `TuningFork.Midi.write!/3`. Building it needs a C
compiler, and on Linux the ALSA headers (`libasound2-dev`).

## TuningFork.Midi.Port

The raw layer: every call is the NIF, and bytes go in and out exactly as they go down the
wire. `TuningFork.Midi.Out` is built on it and is the module to use for playing a score.

Reading: `open_input/2` names a process to send to, and `listen/1` starts the flow. Messages
arrive as `{:midi_in, port, bytes, monotonic_nanoseconds}`, one complete message per send,
delivered from the backend's own thread. The owner is monitored: a port whose owner dies is
closed and reclaimed rather than left open with nobody reading it.

Virtual ports (`open_virtual_output/1`, `open_virtual_input/2`) create a source or
destination of our own that a DAW, a synth or a monitor sees in its own port list and can be
pointed at. That is how to drive something else with no MIDI hardware and no loopback bus set
up first. Not every backend has them: Windows answers `{:error, :no_backend}`, since WinMM
has no such thing; a loopback driver is the way there.

Without a device: every function answers `{:error, reason}` rather than raising when there is
no port to be had, so a program that runs both with and without a MIDI device does not have
to branch. Where the NIF itself could not be built, `available?/0` is false and nothing else
works.

## TuningFork.Midi.Message

Builds MIDI messages as binaries. Channels are 1 to 16 as musicians count them and go on the
wire as 0 to 15. Notes, velocities and controller values are 0 to 127 and are clamped rather
than wrapped, so a velocity worked out from a gain of 1.2 is loud rather than quiet.

`hush/1` is what to send when a piece is stopped part way through: sustain pedal up, all
notes off, all sound off, so nothing is left ringing.

## TuningFork.Midi.Out

Plays a `TuningFork.Score` out of a port. Nothing is synthesised: a note becomes a note-on
and a note-off, and whatever is listening makes the sound. A voice's pitch becomes the
nearest MIDI note, its gain becomes velocity, and how long it sounds becomes the gap between
the two messages. A voice carries a frequency rather than a note number, so the nearest
semitone is what goes down the wire; a drum sample's pitch lands on whatever key is nearest
it. A voice with no usable frequency produces no messages.

Timing: every message is scheduled against one monotonic clock reading taken when the player
starts, so the gaps between messages cannot accumulate an error the way sleeping for each in
turn would, and a long or looped piece does not drift. Each round of a loop is offset by the
score's duration from that same start.

Stopping: `stop/1` sends `Message.hush/1` on the channel it used, so nothing is left ringing
in whatever is listening. The player monitors its caller and stops the same way when the
caller dies.

`messages/2` is the pure part: it returns the timed byte list that `play/3` walks, so a
score's MIDI can be inspected without a device.

### Live patterns

`pattern/3` walks a `TuningFork.Pattern` the way `TuningFork.Pattern.Player` does for audio,
but on a wall clock: every 25 ms it works out the cycle the clock has reached, looks 150 ms
ahead, queries the pattern for the onsets in that window and schedules their note on and
note off messages with `Process.send_after/3` against the origin it took when it started.
The origin is re-taken when the tempo changes, so a new `cps` bends time from that moment
without a jump. A swap asked for at the cycle line is installed when the scheduled window
crosses an integer cycle, so the new pattern's first cycle is complete. Drums have no
frequency, so a kit drum name is looked up in a General MIDI percussion table and sent on
channel 10; that table is the one Strudel's drum names map onto. MIDI clock, when asked
for, is 96 pulses a cycle from the same origin, so a DAW following it sees four beats to
the cycle.

## TuningFork.Midi.In

An input played on a stage. Every message the port delivers is parsed with
`Message.parse_all/1`; a note on becomes `TuningFork.Stage.hold/3` under the key
`{channel, note}` with a voice built from the listener's `:voice` option and the note and
velocity, and a note off becomes `TuningFork.Stage.release/3` of that key. The sustain pedal
(controller 64) moves released keys to a pedal set instead of releasing them, and releases
the whole set when it comes up. The stage holds a voice by stretching its envelope's hold to
an hour and releasing from whatever level it has reached, so a piano voice with no sustain
still decays on its own under a held key. A listener without a port is fed by whoever sends
it `{:midi_in, port, bytes, time}`, which is how it is tested and how another reader can
share one port. `TuningFork.Midi.Message.parse/1` is the pure part: bytes to events, with
a note on at velocity zero read as the note off the wire means by it.
