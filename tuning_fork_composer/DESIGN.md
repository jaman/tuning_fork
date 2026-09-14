# tuning_fork_composer design

The composer is a step sequencer with no way to show itself. Every front end (a Livebook
smart cell, a terminal app, a LiveView) holds a project struct, calls the editing functions on
it, and draws what comes back. This package depends on `tuning_fork` only, and no front end is
part of it.

## TuningFork.Composer

A composition is a struct: tempo, bar count, meter, division, key, scale, base gain, reverb,
a name, and a list of tracks. Grid width is `meter * division` (`steps_per_bar/1`). A step
lasts `1 / division` beats (`step_beats/1`). The piece is `bars * meter` beats long
(`beats/1`).

Every editing function takes a project and returns one. Indices out of range are no-ops,
never errors. Settings accept strings as well as numbers so that a form can pass what it has;
a number that does not parse leaves the setting unchanged, so half-typed input in a form does
not change the tempo or silence the gain. Changing `:meter` or `:division` resizes every
track to the new grid width.

Step edits are addressed by track index then step index. `toggle_step/3` switches a step on
or off and keeps its length. `cycle_step/4` moves a step one degree up or down the scale and
switches it off past either end. `set_step/4` sets a scale degree outright, clamped to the
scale. `set_length/4` and `grow/4` find the note from anywhere inside it, so a drag that
starts mid-note lengthens that note; both clamp at the next note so notes never overlap.

The menus a front end can draw (`drums/0`, `instruments/0`, `scales/0`, `settings/0`) are
plain lists so a front end does not have to know the sound catalogue.

`to_source/1` writes `TuningFork.Part` source that runs anywhere; `to_score/1` builds a
`TuningFork.Score` directly for playing without evaluating source. Both skip muted and empty
tracks. Every instrument is derived from one base voice (`base_voice/1`): drums come from the
General MIDI kit, pitched tracks from a General MIDI program, sample tracks from a WAV file
loaded into the base voice.

A front end is expected to look like this:

    def handle_event({:cell_clicked, track, step}, state) do
      %{state | project: Composer.toggle_step(state.project, track, step)}
    end

## TuningFork.Composer.Track

A track is one row of the grid: an instrument and one entry per step. The `:steps` list is
always the grid's width; `resize/2` grows it with rests or cuts it short.

A step has three forms: `0` for silence, a bare scale degree for a note one step long, and
`{degree, length}` for a note held over several steps. `read/1` normalises all three to
`{degree, length}` and `write/2` produces the shortest form, so callers never pattern match
on the raw step. A `:drum` row only ever holds `0` or `1`; degree and length mean nothing to
it, and switching a track's kind to `:drum` flattens every degree to `1`.

`held/1` marks the steps covered by a note that began earlier, so a front end can draw a held
note as one bar rather than as a lit cell followed by empty ones. `start_of/2` finds the
first step of the note covering a step, and `room_at/2` reports how far a note may stretch
before the next one; together they keep notes from overlapping.

## TuningFork.Composer.Json

Converts a composition to string-keyed maps whose values are numbers, strings, booleans and
lists, and back. The shape survives a round trip through JSON without a codec, which is what
a browser, a file, or a notebook's saved attributes need. JSON has no tuples, so a held step
is carried as `%{"d" => degree, "n" => length}` and a step one long is the bare degree.

`from_map/1` never raises: missing keys fall back to defaults and unrecognisable values are
dropped. Only note names, scale names and track kinds the composer already knows are turned
into atoms, so untrusted input cannot grow the atom table.

## TuningFork.Composer.Source

Writes a composition as `TuningFork.Part` source. The output is run through the formatter and
references nothing from this package, so it can be pasted into any Mix project that depends
on `tuning_fork`.

The `:output` option chooses the last line: `:score` binds the score to a variable named
after the project, `:wav` writes `<name>.wav`, `:kino` returns a `Kino.Audio`.

The written source looks like this:

    import TuningFork.Part

    alias TuningFork.{Gm, Score, Voice}

    base = Voice.new(shape: :saw, gain: 0.5, cutoff: 0.45, envelope: ...)
    kit = Gm.drums()
    bass = Gm.for_program(33, base)

    drum_kick =
      part(bpm: 96, synth: kit[36], gain: 0.9)
      |> repeat(2, fn bar -> steps(bar, "x...x...x...x...", 1 / 4) end)

    pitched_bass =
      part(bpm: 96, synth: bass, gain: 0.5)
      |> repeat(2, fn bar ->
        steps(bar, [{:a2, release: 4 / 4}, nil, ...], 1 / 4, release: 1.5)
      end)

    song = Score.from_parts([drum_kick, pitched_bass], bpm: 96, beats: 8)

Rules the written source follows:

- Step length is written as `1 / division`, never as a decimal.
- Notes are named (`:a2`) rather than looked up in a scale.
- A note one step long inherits the track's `:ring`; a held one carries its own `release:`.
- Two tracks on one instrument get distinct names: `drum_kick`, `drum_kick_2`.
- Only the aliases the piece actually uses are emitted.
- A track or project name that would not compile as a variable is slugged, and a project
  named `"track"` binds to `song`.
