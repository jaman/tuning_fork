# tuning_fork_kino design

Livebook smart cells for TuningFork. This is its own package because Livebook integration
needs Kino, and an application that renders audio in a Phoenix release has no use for it.
Neither `tuning_fork` nor `tuning_fork_speaker` depends on this; this depends on
`tuning_fork` and `tuning_fork_composer`.

None of the cells needs an audio device: `tuning_fork` renders to a buffer, `TuningFork.Wav`
puts a header on it, and the bytes go to the browser. The cells run over ssh and in a
container. Every cell writes ordinary `TuningFork` source that keeps working in a Mix project
with no Livebook and no Kino in it, apart from the last line, which hands the audio to
`Kino.Audio`. Nothing is hidden behind a callback into this package, so converting a cell back
to code keeps it working.

## KinoTuningFork.Player

The looping player both live-coding cells embed. `js/0` returns a JavaScript factory; each cell
interpolates it into its `main.js` and calls `tuningForkPlayer()` to get its own player, so
two cells never share one.

Audio plays through an `AudioBufferSourceNode` with `loop = true`, which loops inside the audio
thread with nothing between the last frame and the first. An `<audio loop>` element seeks back
at the end and waits on the buffer again, which is heard as a pause every time round, so the
player does not use one.

New audio arriving while the player is running starts at the point the old audio had reached,
so an edit lands on the beat. A buffer source's buffer cannot be changed, so a swap is a new
source started at an offset while the old one is stopped. Elapsed time is counted across those
swaps rather than reset by them; an offset past the end of the new buffer wraps into it.

`prime()` makes or resumes the `AudioContext` and must run from a click handler: a context made
outside a user gesture stays suspended.

The player is tested by `test/js/player_test.mjs`, which stubs an `AudioContext` and runs the
player through a swap, a wrap and a stop, asserting what it asks the audio thread to do. The
test is skipped when `node` is not installed; `node` is not a dependency of this package.

## KinoTuningFork.ComposerCell

A step sequencer that writes Elixir. Tracks run down the side, steps across, and a click puts a
note in a box. Drum tracks are on or off; pitched tracks hold a degree of whatever key the
piece is in, so a wrong note is hard to reach. Every change regenerates the source and
re-renders the audio.

The grid width comes from two numbers: how many beats in a bar, and how finely each beat is
divided. Four of four is the sixteen-step grid; three of eight is a waltz written in
thirty-seconds; four of three is triplets. Changing either resizes every row, growing it with
rests or cutting it short. A step length that does not divide evenly is written as a division
rather than a decimal (`1 / 3` rather than `0.333`).

The grid is a way of writing `TuningFork.Part`, not a format of its own. Everything the grid
can express belongs to `TuningFork.Composer` and is tested there against its own API; this
cell only opens on something (`Composer.demo/0` when there are no saved attributes), turns
what the browser sends into a composition and back through `TuningFork.Composer.Json`, and asks
`TuningFork.Composer.Source` for the `:kino` ending. A track needing a sound the grid cannot
describe is served by editing the voice in the generated source.

## KinoTuningFork.MidiCell

Turns a MIDI file into audio the browser can play. The source it writes is ordinary
`TuningFork` calls:

    score =
      "song.mid"
      |> TuningFork.Midi.read!()
      |> TuningFork.Gm.score(gain: 0.2)

    TuningFork.Score.render(score, 44_100)

followed by encoding to WAV and `Kino.Audio.new(:wav)`. No source is written until a path is
filled in. The fields are all strings so the form can save what it has; numbers are parsed
when the source is built, and a variable name that would not compile falls back to `score`.

## KinoTuningFork.LivePatternsCell

A live-coding buffer in the style of pattern languages: rows of pattern source, stacked, playing
on a loop, swapped at the cycle line.

The buffer is one line per row, exactly as `TuningFork.Session` reads rows: a row parked behind
`--`, `//` or `_` plays nothing; a row beginning `|>` carries on the one above; every other row
starts a pattern of its own. Evaluating folds every switched-on row into one
`TuningFork.Pattern` and plays it. A buffer that reads as Strudel — a piece pasted from
strudel.cc — is translated by `TuningFork.Session` on the same path, and the cps field takes
the tempo its `setcps` sets; the `evaluated` event carries the cps in effect so the field
follows.

What a row means, what it plays, why it will not parse and what to draw under it all come from
`TuningFork.Session` and `TuningFork.Session.View`, and are tested there. This module only
keeps the buffer and turns the numbers those two give back into events for the browser to
draw.

Evaluate starts the pattern on a `TuningFork.Stage` the cell owns, with `KinoTuningFork.Sink`
streaming the mix to the page (see below), or swaps it in at the next cycle line when one is
already playing, so an edit lands on the beat. Stop stops the stage and the player. The cycle
shown, and the scopes and pianorolls drawn under the rows, are polled from the stage every
100 ms.

The source it writes starts the same pattern on the notebook's named stage, rendering a
`KinoTuningFork.stage/0` widget first if there is none, so the notebook plays live when run
from the top:

    unless Process.whereis(TuningFork.Stage), do: Kino.render(KinoTuningFork.stage())

    rows = [%{source: "s(\"bd*4\")"}, %{source: "|> gain(0.8)"}]
    pattern = TuningFork.Session.combined(rows)

    if TuningFork.Stage.cycle() do
      TuningFork.Stage.update_pattern(pattern, at: :cycle)
    else
      TuningFork.Stage.start_pattern(pattern, cps: 0.5)
    end

`to_source/1` returns `""` when every row is parked or the buffer is blank.

## KinoTuningFork.LiveLoopsCell

A live-coding board of named loops, each on its own length, swapped when the loop comes round.
Where `KinoTuningFork.LivePatternsCell` folds every row into one pattern, a loop here stands
on its own (its own name, source and length) and several run at once without being stretched
to fit each other.

A loop's source is ordinary Elixir that must come to a `%TuningFork.Part{}` or a
`%TuningFork.Score{}`. `TuningFork.Part` is imported and `TuningFork.Kit` is aliased, exactly
as they are in `mix tuning_fork.loops`, so a loop written in one plays the same in the other.
Reading a loop is `TuningFork.Part.Source.parse/1`, the same function the terminal front end
uses; what a loop is belongs to `TuningFork.Part.Source` and how loops sound together to
`TuningFork.Transport`, and both are tested where they live.

    part(bpm: 120, synth: Kit.voice("bd", 0.3))
    |> steps("x...x...x...x...")

`Kit.voice/2` names a sound: `Kit.voice("bd", 0.3)` is a kick,
`Kit.voice(%{note: "c2", shape: :saw}, 0.4)` a bass note. A bare `TuningFork.Voice` is a raw
oscillator at 440 Hz. `TuningFork.Part.Source.reference/0` is the whole vocabulary, and is what
the "?" button shows. The demo board (a four-beat kick and a four-beat bass) is the same pair
of loops `mix tuning_fork.loops` opens on.

Evaluate reads every named loop, renders the lot together with
`TuningFork.Transport.render_rounds/4` over `TuningFork.Transport.loop_seconds/2` seconds (so
every loop is in the audio a whole number of times), and hands the audio to
`KinoTuningFork.Player`, which loops it without a gap. Stop stops that player. A loop taken off
the board is out of the sound from the next evaluation. Evaluating again comes in where the
player already was rather than at the top, so an edit lands on the beat. No `TuningFork.Stage`
is started, for the same reason as in the patterns cell. Each loop's beat and round come from
`TuningFork.Transport.at/2`, given the position the player reports every 200 ms.

The source it writes:

    {:ok, drums_score} =
      TuningFork.Part.Source.parse("""
      part(bpm: 120, synth: Kit.voice("bd", 0.3))
      |> steps("x...x...x...x...")
      """)

    scores = [drums_score]

    scores
    |> TuningFork.Transport.render_loops(44_100, TuningFork.Transport.loop_seconds(scores, 8))
    |> TuningFork.Wav.encode(rate: 44_100, channels: 2)
    |> Kino.Audio.new(:wav, loop: true)

The `Kino.Audio` it writes has no `autoplay`, so it waits to be pressed rather than playing
over the cell's own player. `to_source/1` leaves out any loop with a blank name or a blank
source, and returns `""` when none are left. A loop's name is a label for the loop and for what
the player reports about it; it reads best as an identifier (`"drums"`, not
`"the drums part"`), and a name that does not make a valid variable falls back to
`loop_<index>_score` in the written source.

## KinoTuningFork.Sink and KinoTuningFork.Stage

A notebook has no speaker, so a `TuningFork.Stage` runs on the server with `KinoTuningFork.Sink`
as its sink. The sink sends every chunk to its owner process as `{:pcm, binary}` and then
sleeps until the audio sent so far is `lead` seconds (0.75 by default) ahead of the wall clock,
which is what keeps the page fed a little ahead without letting the stage run away. The owner —
the stage widget or a live-coding cell — forwards each chunk to the page as a binary event, and
`KinoTuningFork.Player` schedules it with Web Audio right after the previous one, so playback
is gapless and there is no buffer to wrap. A chunk of 2048 frames at 44.1 kHz is 46 ms, about
twenty messages a second.

A browser starts audio only from a click, so the player takes chunks only after **▶ listen** or
**Evaluate** has been pressed; chunks that arrive before are dropped and the stage keeps
running. Looping a fixed buffer was replaced by streaming because Chromium's
`AudioBufferSourceNode` loop reads past the buffer's end when `duration × sampleRate` rounds
above the length — a 20.1-second buffer at 48 kHz froze into a constant tone at its wrap.

The stage widget owns a stage registered as `TuningFork.Stage` by default, which is where a
bare `live_loop` lands, and a second widget stops the first's stage and takes the name. The two
live-coding cells each own an unnamed stage of their own; **Evaluate** starts a loop or pattern
on it, or swaps it in at the next round or cycle, and readouts are polled from the stage rather
than derived from a player position. The source a cell writes out starts the same thing on
the notebook's named stage, so the notebook plays live when run from the top.
