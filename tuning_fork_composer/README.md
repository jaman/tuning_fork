# TuningForkComposer

A step sequencer as data. No process, no screen — a struct and pure functions over it, so the
same composer can be drawn by a terminal, a notebook or a web page.

```elixir
{:tuning_fork, "~> 0.1"},
{:tuning_fork_composer, "~> 0.1"}
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
```

## Modules

| Module | For |
| --- | --- |
| `TuningFork.Composer` | The project struct, and every edit |
| `TuningFork.Composer.Track` | One row: its instrument and its steps |
| `TuningFork.Composer.Source` | Writing a project out as Elixir |
| `TuningFork.Composer.Json` | To and from string-keyed maps, for the wire |

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

## Front ends that exist

| Package | Draws with |
| --- | --- |
| `tuning_fork_drafter` | Drafter, in a terminal — `mix tuning_fork.compose` |
| `tuning_fork_kino` | Kino, in Livebook — the **Compose** smart cell |

Neither knows about the other, and this package knows about neither.
