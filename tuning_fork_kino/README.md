# KinoTuningFork

Livebook smart cells for [TuningFork](https://hex.pm/packages/tuning_fork).

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fjaman%2Ftuning_fork%2Fmain%2Ftuning_fork_kino%2Fnotebooks%2Fcomposer.livemd)

## Setup

In the notebook's **setup cell** — the one at the very top, not an ordinary cell:

```elixir
Mix.install([
  {:tuning_fork, "~> 0.1.3"},
  {:tuning_fork_samples, "~> 0.1.3"},
  {:tuning_fork_kino, "~> 0.1.3"}
])
```

Working from a checkout instead, give each a `path:` — `{:tuning_fork_kino, path: "/absolute/path/to/tuning_fork_kino"}` — and re-run the setup cell after editing the code.

The notebooks open in Livebook from the badges; each fetches what it needs.

| Notebook | | |
| --- | --- | --- |
| `notebooks/composer.livemd` | The tour: one tune written three ways — the Compose grid, a TF Patterns cell in Strudel's syntax, TF Loops — on the same recordings, then MIDI to audio and the same from code | [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fjaman%2Ftuning_fork%2Fmain%2Ftuning_fork_kino%2Fnotebooks%2Fcomposer.livemd) |
| `notebooks/strudel.livemd` | A Strudel piece pasted into a TF Patterns cell — eddyflux's "coastline" with its sample pack — and the same from code | [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fjaman%2Ftuning_fork%2Fmain%2Ftuning_fork_kino%2Fnotebooks%2Fstrudel.livemd) |
| `notebooks/sonic_pi.livemd` | The Sonic Pi website examples, each in a cell | [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fjaman%2Ftuning_fork%2Fmain%2Ftuning_fork_kino%2Fnotebooks%2Fsonic_pi.livemd) |

## A stage in the notebook

```elixir
use TuningFork.SonicPi
KinoTuningFork.stage()
```

The stage cell shows a player: press **▶ listen** once. From then on any cell is Sonic Pi:

```elixir
live_loop :bells do
  sample :perc_bell, rate: rrand(0.125, 1.5)
  sleep rrand(0, 2)
end
```

Evaluating a loop cell again swaps the loop in when it next comes round; a `play` or
`sample` at the top of a cell sounds at once; `hush()` stops everything. The stage streams
what it mixes to the page as it plays, so nothing is rendered ahead and there is no file.
`KinoTuningFork.stage(name: nil)` gives a stage a bare `live_loop` does not see, for use
through `live_loop :name, stage: pid do … end`.

## Smart cells

**+ Smart** in the cell menu, and pick one of:

| Cell | For |
| --- | --- |
| **Compose** | Writing a piece visually, in a grid, without writing code |
| **MIDI to audio** | Turning a `.mid` into sound |
| **TF Patterns** | Live coding patterns, the Strudel/TidalCycles way |
| **TF Loops** | Live coding named loops, the Sonic Pi way |
| **TF MIDI** | A MIDI keyboard played in and heard, a pattern played out with clock, both lit on one key strip; needs `tuning_fork_midi` in the setup cell |

The two live-coding cells each run a stage of their own and stream it to the page, so the
**Evaluate** button inside the cell swaps the music in at the next cycle or round rather than
rendering a file. Evaluating the notebook cell itself runs the source the cell wrote — the same
loops as `live_loop` blocks — on the notebook's named stage from `KinoTuningFork.stage()`.

Smart cells are registered when the package's application starts, which happens during
`Mix.install`. If nothing appears in the menu:

- It has to be the **setup cell**. Installing from an ordinary cell registers too late for
  the menu to see it.
- Livebook caches installs. After changing the package, re-run with
  `Mix.install([...], force: true)` and reconnect the runtime.
- Both paths must be absolute. `tuning_fork_kino` depends on `tuning_fork` by relative path,
  so listing both keeps them pointing at the same copy.

## Compose

A step sequencer. Tracks down the side, steps across, a click puts a note in a box.

Drum tracks are on or off. Pitched tracks hold a degree of whatever key the piece is in — a
click walks up the scale, a right-click walks down — so a wrong note is hard to reach. Drag a
note to the right to hold it over the steps that follow.

| Control | What it does |
| --- | --- |
| Tempo, Bars | How fast and how long |
| Beats/bar, Steps/beat | The shape of the grid. 4 and 4 is sixteen sixteenths; 3 and 8 is a waltz; 4 and 3 is triplets |
| Key, Scale | What the pitched tracks are allowed to play |
| Kit | `synth` for the kit's own drums and synthesised instruments, or a drum machine — `RolandTR909` and the others in `TuningFork.Kit.banks/0` — for its recordings and General MIDI soundfonts, fetched as they are first heard |
| Gain | Level per note. Lower it as tracks pile up |
| Reverb | Room size, 0 to 1 |
| + track | Add a row; each one picks drum or pitched, and a sound |

Per track: **M** mutes it (dimmed, and left out of the generated code — unmuting brings it
back untouched), **ring** is how long its notes sound by default in beats, and a note dragged
out overrides that for itself. The text box after ring is which bars the track plays, one
character per repeat of the grid — `x` plays, `.` rests, cycled over the bars — so
`..xxxxxx..xxxx` waits two bars, drops out for two and comes back; empty plays them all.

### The source is the artifact

The grid is a way of writing `TuningFork.Part`, not a format of its own:

```elixir
import TuningFork.Part

alias TuningFork.{Gm, Notes, Score, Voice}

base = Voice.new(shape: :saw, gain: 0.5, cutoff: 0.45, ...)
kit = Gm.drums()
bass = Gm.for_program(33, base)

drum_kick =
  part(bpm: 96, synth: kit[36], gain: 0.9)
  |> repeat(2, fn bar -> steps(bar, "x...x...x...x...") end)

pitched_bass =
  part(bpm: 96, synth: bass, gain: 0.5)
  |> repeat(2, fn bar ->
    steps(bar, [:a2, nil, nil, nil, :a2, nil, nil, nil, :e3, nil, nil, nil, :d3, nil, nil, nil])
  end)

song = Score.from_parts([drum_kick, pitched_bass], bpm: 96, beats: 8)
```

That runs in a Mix project with no Livebook, no Kino, and nothing of this package in sight.
Convert the cell back to code and it keeps working — which is the point of composing here
rather than in something that exports a `.mid`.

Notes are written out by name rather than as lookups into a scale, so a line can be read and
one note changed without working out what index it was. Change the key in the cell and it
rewrites them; change them in the code and the cell is no longer in charge, which is the
right way round.

### What it cannot do

Sixteen steps, one note per step per track. No chords in a single row — stack two tracks on
the same instrument instead — and no note lengths, since every step is a sixteenth. Those are
grid limits, not `TuningFork.Part` limits: take the generated source and it will do whatever
`part/1` will do.

## MIDI to audio

Point it at a `.mid`, set tempo, gain, drum handling and reverb, and play the result in the
browser. Same principle — a form over generated code.

Livebook has no sound card and does not need one. `tuning_fork` is pure Elixir and renders to
a buffer, `TuningFork.Wav` puts a header on it, and `Kino.Audio` hands the bytes to the
browser, so this works over ssh and in a container.

## TF Patterns

Live coding patterns, the Strudel/TidalCycles way. One pattern per row; every switched-on row
is folded into one pattern and played on a loop.

```
s("bd*4")
|> gain(0.8)
|> scope()
```

A row starting `|>` carries on the row above it. A row behind `--`, `//` or `_` is switched
off. A row asking for `scope()` or `pianoroll()` gets one drawn under it, moving with the
sound.

| Control | What it does |
| --- | --- |
| Evaluate, or `Ctrl+Enter` | Start the pattern, or swap it in at the next cycle line |
| Stop | Stop |
| cps | Cycles per second, taking effect as it is changed |
| Volume | Level |

An edit lands at the next cycle line rather than sending the pattern back to cycle zero. A row
that will not parse is reported underneath it and the rest still play.

Same vocabulary as `mix tuning_fork.live`, so a buffer moves between the two.

A piece pasted from strudel.cc plays as written — `$:` rows, method chains, `let` variables,
`setcps`, `samples('github:…')` — and the cps field takes the tempo the piece sets. An
error is reported under the line it came from. See `TuningFork.Strudel` for what is read.

```
setcps(.75)
let chords = chord("<Bbm9 Fm9>/4").dict('ireal')
$: s("bd").struct("<[x*<1 2> [~@3 x]] x>").bank('crate')
$: chords.offset(-1).voicing().s("gm_epiano1:1").room(.5)
```

## TF Loops

Live coding named loops, the Sonic Pi way. Each loop has its own name, source and length, and
they run against each other without being stretched to fit — a four-beat loop against a
three-beat one keeps that relationship.

```elixir
part(bpm: 120, synth: Kit.voice("bd", 0.3))
|> steps("x...x...x...x...")
```

or in Sonic Pi's words:

```elixir
sample :perc_bell, rate: rrand(0.125, 1.5)
sleep rrand(0.5, 2)
```

A loop's source is Elixir under `use TuningFork.SonicPi`: a `TuningFork.Part` pipeline must
come to a part or a `TuningFork.Score`, and a Sonic Pi block is the round it played. `?`
lists both vocabularies. Sample names come from `tuning_fork_samples`, listed above.

| Control | What it does |
| --- | --- |
| Evaluate, or `Ctrl+Enter` | Start every loop, or swap each changed one in when it comes round |
| Stop | Stop |
| + loop | Add a loop, opening on a drum part that plays as it stands |
| × | Remove a loop |
| ? | What a loop can be written with |
| Volume | Level |

Each loop shows the beat and the round it is on, and `waiting` while an edit is held for its
downbeat. A loop taken off the board stops when it next comes round. A loop that will not read
is reported under it and the rest still play.

Same vocabulary as `mix tuning_fork.loops`, so a board moves between the two.

## Sound in a notebook

A notebook has no speaker: it runs on a server and is looked at through a browser. The stage
widget and the live-coding cells run a `TuningFork.Stage` on the server with
`KinoTuningFork.Sink`, which streams each chunk to the page a little ahead of real time, and
the page schedules them back to back with Web Audio. That works over ssh and in a container,
and a browser will only start audio from a click — which is what **▶ listen** and **Evaluate**
are.

The source a smart cell writes out is the same live code — `live_loop` blocks under
`use TuningFork.SonicPi`, or `Stage.start_pattern` — and plays on the notebook's named stage,
so it needs a `KinoTuningFork.stage()` cell above it.
