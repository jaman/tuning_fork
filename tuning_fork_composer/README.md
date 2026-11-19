# TuningForkComposer

A step sequencer as data. No process, no screen — a struct and pure functions over it, so the
same composer can be drawn by a terminal, a notebook or a web page.

```elixir
def deps do
  [
    {:tuning_fork, "~> 0.1.12"},
    {:tuning_fork_composer, "~> 0.1"}
  ]
end
```

```elixir
alias TuningFork.Composer

project =
  Composer.new(bpm: 100)
  |> Composer.add_track(kind: :drum, sound: "kick")
  |> Composer.toggle_step(0, 0)
  |> Composer.toggle_step(0, 4)

Composer.to_source(project)   # Elixir source, as a string
Composer.to_score(project)    # a TuningFork.Score, ready to render
Composer.to_song(project)     # a TuningFork.Song: one section, a stem per track
```

## Modules

| Module | For |
| --- | --- |
| `TuningFork.Composer` | The project struct, and every edit |
| `TuningFork.Composer.Track` | One row: its instrument and its steps |
| `TuningFork.Composer.Source` | Writing a project out as Elixir |
| `TuningFork.Composer.Json` | To and from string-keyed maps, for the wire |
| `TuningFork.Composer.Song` | Describing the project as a song bundle |
| `TuningFork.Composer.Bake` | Rendering the bundle's audio and score |
| `TuningFork.Composer.Arrangement` | A song as tracks of clips placed on bars, with sections and markers |
| `TuningFork.Composer.Arrangement.Clip` | Notes, steps, a pattern, a Strudel chain, a Sonic Pi loop or a recording |
| `TuningFork.Composer.Arrangement.Track` | An instrument, its clips, and its level, pan and send |
| `TuningFork.Composer.Arrangement.Json` | An arrangement to and from JSON-safe maps |
| `TuningFork.Composer.Arrangement.Render` | A stem per track and the mix |
| `TuningFork.Composer.Arrangement.Bake` | An arrangement as a song bundle |
| `TuningFork.Composer.Arrangement.Flatten` | Every clip that can be read as notes, as notes |

## The grid

`meter` beats to a bar, `division` steps to a beat. Width is their product.

| Want | `meter` | `division` | Steps |
| --- | --- | --- | --- |
| the usual | 4 | 4 | 16 |
| a waltz | 3 | 4 | 12 |
| triplets | 4 | 3 | 12 |
| 5/4 | 5 | 4 | 20 |
| thirty-seconds | 4 | 8 | 32 |

`Composer.set(project, :meter, 3)` resizes every track for you — grown with rests, or cut
short.

## Sections

A project with no sections plays its grid `bars` times. Give it sections and they say how
the song is laid out instead: a name, a length in bars, and the tracks that sound in it.

```elixir
project
|> Composer.add_section("intro", 2, tracks: [0, 1])
|> Composer.add_section("verse", 4)
|> Composer.add_section("chorus", 4)
```

`Composer.sections/1` gives them back, and a project without any is one section named after
`:name`, `:bars` long, so nothing that reads a project has to special-case the simple one.
A track's `:plays` starts again with each section, so `"x."` is every other bar of every
section it is in; `Composer.passes_at/2` is the whole song's on/off string for a track.

Baking writes one `sections` entry per section, in order, with the times a game cues them
by.

## Steps

A step is one of three things:

```elixir
0           # silence
3           # scale degree 3, one step long
{3, 4}      # scale degree 3, held over 4 steps
```

Read them with `Track.read/1`, which normalises all three to `{degree, length}`, and build
them with `Track.write/2`. Degree 1 is the first note of `Composer.scale(project)`.

## Writing a front end

Hold a project. Turn input into one call. Draw what comes back.

```elixir
def handle_event({:cell_clicked, track, step}, state) do
  %{state | project: Composer.toggle_step(state.project, track, step)}
end

def handle_event({:cell_dragged, track, from, to}, state) do
  %{state | project: Composer.set_length(state.project, track, from, to - from + 1)}
end
```

Every editing function takes a project and returns one. Indices out of range are no-ops, so
there is nothing to check before calling.

To draw a row:

```elixir
track = Composer.track(project, index)
held = Track.held(track)      # [false, true, true, false, ...]

for {step, i} <- Enum.with_index(track.steps) do
  case Track.read(step) do
    {0, _} -> if Enum.at(held, i), do: "held", else: "empty"
    {degree, _} -> "note #{degree}"
  end
end
```

For menus: `Composer.drums/0`, `Composer.instruments/0`, `Composer.scales/0`,
`TuningFork.Kit.banks/0` for the `:kit` setting, and `Composer.settings/0` for what `set/3`
accepts.

A track's `:plays` says which repeats of the grid it sounds on — `"..xx"` waits two bars —
as a string of `x` and `.` cycled over the piece's bars; `Composer.passes/2` resolves it,
and `nil` plays them all.

`:kit` chooses the sounds: `:synth` is the kit's own drums and `TuningFork.Gm` synth voices,
with nothing to fetch; a drum machine name such as `"RolandTR909"` plays that machine's
recordings and the General MIDI soundfonts, through `TuningFork.Kit.instrument/4`, fetched
the first time they are heard.

## Playing and writing

```elixir
# play what is on screen, without evaluating source
project |> Composer.to_score() |> TuningFork.Score.render(44_100)

# write source that runs on its own
File.write!("song.exs", Composer.to_source(project, output: :wav))
```

Both skip muted and empty tracks.

## Baking a bundle

A bundle is a directory a game reads with `tuning_fork` alone: the mix, a recording per
stem, the score, and the `song.json` that names them. Nothing is generated at load.

```console
$ mix tuning_fork.bake song.json
test: 2 stems, 1.0s at 44100 Hz -> track/song
```

```elixir
{:ok, song} = TuningFork.Composer.Bake.bake(project, "priv/music/night", rate: 48_000)
TuningFork.Song.validate(song, dir: "priv/music/night")   # :ok
```

Bake at the rate the game plays at, not the one you monitor at: the bundle stores the rate,
and a mismatch is resampled at load. `score.mid` is a format 1 file — a conductor track with
the tempo and time signature, then a track per stem, drums on channel 10.

## Arrangements

An arrangement is a song laid out on bars rather than repeated from one grid. Each track has
an instrument and clips, and each clip starts on a bar and runs for a number of beats. A clip
holds notes, drum steps, a pattern on the track's instrument, a Strudel chain, a Sonic Pi
loop or a recording.

```elixir
alias TuningFork.Composer.Arrangement
alias TuningFork.Composer.Arrangement.{Bake, Clip, Track}

arrangement =
  Arrangement.new(
    name: "river",
    bpm: 132,
    sections: [%{name: "road", bar: 1, bars: 8}, %{name: "river", bar: 9, bars: 8}],
    markers: [%{name: "fall", bar: 17, beat: 0.0}],
    tracks: [
      Track.new(
        name: "drums",
        instrument: "kick",
        clips: [Clip.new(kind: :steps, beats: 64.0, steps: %{"kick" => "x...x...", "hat" => "x.x.x.x."})]
      ),
      Track.new(
        name: "bass",
        instrument: "bass",
        gain_db: -2.0,
        clips: [Clip.new(kind: :pattern, beats: 64.0, pattern: "x--.x--.", pitches: [38, 41])]
      ),
      Track.new(
        name: "lead",
        instrument: "gm_flute",
        send: 0.3,
        clips: [
          Clip.new(
            kind: :notes,
            bar: 9,
            beats: 32.0,
            notes: [%{beat: 0.0, pitch: 69, length: 1.0, velocity: 0.8, sound: nil}]
          )
        ]
      ),
      Track.new(
        name: "pad",
        instrument: "strings",
        clips: [Clip.new(kind: :strudel, beats: 80.0, strudel: ~S|note("<[d3,f3,a3] [bb2,d3,f3]>").slow(2)|)]
      )
    ]
  )

{:ok, song} = Bake.bake(arrangement, "priv/music/river", rate: 48_000, playable: ["lead"])
```

Patterns use the compact notation of `TuningFork.Composer.Arrangement.Pattern`: `x` and `X`
accent, `o` a normal hit, `.` a rest, `-` holds, `|` and spaces are skipped. A pattern on a
pitched track plays `pitches` or `chords` one per hit, cycling. Steps and patterns repeat to
fill their clip, and every note is cut at its clip's end.

The baked bundle has a stem per audible track, the arrangement's sections with their
seconds, its markers under `"markers"`, and every stem's notes (`"notes"`) or drum hits
(`"hits"`) with their bar and beat, so a game can chart any stem.

`TuningFork.Composer.Arrangement.Json` writes an arrangement as JSON for other programs, with
`"format": "tuning_fork.arrangement"`, and `mix tuning_fork.bake` bakes such a file:

```console
$ mix tuning_fork.bake river.arrangement.json --rate 48000 --playable lead
river: 4 stems, 36.4s at 48000 Hz -> river
```

A program that plays notes and nothing else takes `TuningFork.Composer.Arrangement.Flatten.with_notes/1`,
which rewrites steps, patterns and Strudel clips as the notes they play.

## Front ends that exist

| Package | Draws with |
| --- | --- |
| `tuning_fork_drafter` | Drafter, in a terminal — `mix tuning_fork.compose` |
| `tuning_fork_kino` | Kino, in Livebook — the **Compose** smart cell |
