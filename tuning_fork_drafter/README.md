# TuningForkDrafter

Four terminal front ends for [tuning_fork](https://hex.pm/packages/tuning_fork), drawn with Drafter.

```bash
cd tuning_fork_drafter
mix deps.get                # first time only
mix tuning_fork.live        # live coding patterns, like Strudel
mix tuning_fork.loops       # live coding named loops, like Sonic Pi
mix tuning_fork.compose     # step sequencer, like a drum machine
mix tuning_fork.midi        # a MIDI keyboard in, a pattern out, both on one key strip
```

## Which one

**`compose` is for composing visually rather than by writing code.** Notes are placed on a
grid with the arrows and the mouse, and nothing has to be typed — which is the whole point of
it, not a limitation of it. It writes ordinary `TuningFork.Part` source out with `w`, so a
tune begun on the grid can be carried on in code by anyone who wants to, but it is a complete
way of working on its own.

`live` and `loops` are the two live-coding models, for writing music *as* code. They are
genuinely different from each other rather than two skins on one thing:

| | `mix tuning_fork.live` | `mix tuning_fork.loops` |
| --- | --- | --- |
| after | Strudel, TidalCycles | Sonic Pi |
| a row is | a pattern — a query over time | a named loop of `TuningFork.Part` code |
| written as | mini-notation and chains | Elixir, a cursor moving through beats |
| everything shares | one cycle | nothing — each loop has its own length |
| an edit lands | at the next cycle line | when that loop comes round |

All three sit on the same core. What a row means is `TuningFork.Session`, what it draws is
`TuningFork.Session.View`, and what it plays through is `TuningFork.Stage` — none of that
lives here.

---

# Live coding

```bash
mix tuning_fork.live
mix tuning_fork.live --cps 0.75
mix tuning_fork.live --pattern "bd*4" --pattern "hh*8?"
```

One mini-notation (`TuningFork.Pattern.Mini`) pattern a row, as many rows
as you write. `Ctrl+E` and it takes over **at the next cycle line** — nothing stops.

```
Live
▶  cycle 12.44 · 0.50 cps · 4 on

1 ▸ s("bd!4") |> scope()
2   hh*8?0.2
3   ~ [cp] ~ cp
4   n("<0 [4] 0 9 7>*16")
5   |> scale("g:minor") |> transpose(-12) |> shape(:saw)
6   |> cutoff(220) |> resonance(16)
7   |> lpenv(2.7) |> lpsustain(0.1) |> lpdecay(0.14)
8   |> pianoroll()
```

**`Enter` breaks a line in two**, so a chain is written down the screen — a row starting `|>`
carries on the one above it. Backspace at the start of a line joins it back. There is no row
count to run out of.

**The token sounding right now is bracketed** — `~ [cp] ~ cp`, `<0 [4] 0 9 7>` — on every row,
following `<>` alternation and `*n` as the pattern engine plays them.

**A row draws nothing unless it asks.** End a chain with `pianoroll()` or `scope()`. A scope
traces the row it is written under, rendered from that row alone rather than read off the
speakers. In a pianoroll the note sounding is drawn hollow.

**`--`, `//` or `_` in front of a line parks it.** `Tab` puts a marker on and takes off
whichever of the three is there. A parked line is not played, not drawn and not checked, so a
half-written one sitting behind an `_` never reports anything.

**Press `?` for the sound names** — every drum the kit knows, how to write notes, the whole
notation and the keys, generated from the kit itself so it cannot drift.

| Key | Effect |
| --- | --- |
| Any character | Type into the slot |
| `←` `→` `Home` `End` | Move along the line |
| `↑` `↓` | Move between slots |
| `Ctrl+E` | Evaluate — in at the next cycle |
| `Ctrl+R` | Evaluate — in now |
| `Enter` | Break the line in two |
| `Tab` | Comment the slot out, or back in |
| `Ctrl+P` | Play and pause |
| Click the `▶` line | The same |
| Click a row | Put the cursor where you clicked |
| `Alt+.` `Alt+,` | Faster, slower |
| `Ctrl+F` `Ctrl+D` | The same, where alt is not sent |
| `Ctrl+K` | Empty this slot |
| `?` | The sound names and the notation |
| `Ctrl+Q` | Quit |

## Sound names

`?` in the app is the live list. In code it is `TuningFork.Kit`:

```elixir
TuningFork.Kit.drums()      # every drum name
TuningFork.Kit.families()   # the same, grouped by kind
TuningFork.Kit.notes()      # c0 to b8
```

| | |
| --- | --- |
| kick | `bd` `kick` |
| snare | `sn`/`snare` · `rim` · `cp`/`clap` |
| hat | `hh`/`hat` · `oh`/`open` |
| tom | `lt` · `mt`/`tom` · `ht` |
| cymbal | `rd`/`ride` · `cr`/`crash` |
| percussion | `tam` · `cow` · `perc` · `sh`/`shaker` |

`bd:3` shifts a drum's pitch. Notes are a letter, `s` for sharp or `b` for flat, and an
octave — `c3`, `fs4`, `eb2`. A whole number is a MIDI note (`69` is a4); a number with a
decimal point is hertz (`440.0`).

A slot that will not parse says why underneath and keeps playing what it played before, so a
half-typed edit never drops out.

Slots holding a piece from strudel.cc — `$:` rows, method chains, `let` variables, `setcps`,
`samples('github:…')` — play as written, and evaluating takes the tempo the piece sets. An
error lands on the line it came from. See `TuningFork.Strudel` for what is read.

| Option | Default | Meaning |
| --- | --- | --- |
| `--cps N` | 0.5 | Cycles per second |
| `--pattern S` | a demo | A row to open on, repeatable |
| `--text` | off | Block characters even where the terminal could draw pixels |

## Drawing

Where the terminal has a pixel protocol — kitty, iTerm2 or sixel — each row draws a pianoroll
through french_curve. Everywhere else it draws blocks. `--text` forces
blocks.

An image per row per frame is what makes a terminal flicker, so:

- **paused, nothing is redrawn at all** — `Ctrl+P` is for the quiet screen as much as the quiet
  speakers
- pictures are rebuilt on a 100 ms clock, not every frame, in a process of their own so that
  building them never sits between a keystroke and the screen
- **only rows that ask get one** — `pianoroll()` or `scope()` on the end of a chain

If it still flickers on your terminal, `--text` is always steady.

## When the pictures do not keep up

A terminal app cannot print — the screen belongs to the drawing — so it writes a trace instead:

```bash
TUNING_FORK_TRACE=/tmp/live.log mix tuning_fork.live
```

Every tick logs the cycle it read and whether the last frame was still being built; every frame
logs how long it waited and how long it took. A tick logging `drawing=true` was dropped, which
is what to look for.

---

# MIDI

```bash
mix tuning_fork.midi
mix tuning_fork.midi --voice gm_epiano1 --pattern 's("bd*4, hh*8")'
```

`i` and `o` walk the inputs and outputs the machine has, ending on a virtual port of the
app's own that other software sees by name. Keys played on the input sound on this machine
with the instrument `v` picks and light the strip blue; `p` plays the pattern out of the
output with MIDI clock and lights what it sends yellow; `←` `→` and enter send one key. `e`
edits the pattern — one expression, as a row of `mix tuning_fork.live` is; `+` and `-` set
the cycles per second; the log under the strip shows both streams. With no device at all,
open the two virtual ports and point a soft synth at "TuningFork Out".

---

# Named loops

```bash
mix tuning_fork.loops
mix tuning_fork.loops --loop 'drums=part(bpm: 120, synth: Kit.voice("bd", 0.3)) |> play(:c3, 1)'
```

Each loop is a block of Elixir, written either with
`TuningFork.Part` — a cursor moving through beats,
where `play` sounds a note and moves on — or in Sonic Pi's words, where `play` and `sample`
sound at the cursor and `sleep` moves it:

```
bells   use_bpm 120
        sample :perc_bell, rate: rrand(0.125, 1.5)
        sleep rrand(0.5, 2)

acid    use_synth :tb303
        with_fx :reverb, mix: 0.3 do
          times 16 do
            play choose(chord(:e3, :minor)), release: 0.1, cutoff: rrand_i(50, 90)
            sleep 0.125
          end
        end
```

A `Part` pipeline must come to a `Score` or a `Part`; a Sonic Pi block is the round it
played, as long as its sleeps. `?` lists both vocabularies. Sample names need the
`tuning_fork_samples` package, which this one lists as an optional dependency.

```
Loops
▶  2 loops

drums ▸ part(bpm: 120, synth: Kit.voice("bd", 0.3))
        |> play(:c3, 1) |> play(:c3, 1)
        round 7 · beat 1.5

bass    part(bpm: 120, synth: Kit.voice(%{note: "c2", shape: :saw}, 0.4))
        |> play(:c2, 2) |> play(:g2, 2)
        round 3 · beat 0.5 · waiting
```

**`Ctrl+E` takes over when that loop comes round** — not at some shared cycle line, so a
four-beat loop and a three-beat one each land on their own downbeat. `waiting` marks a loop
holding an edit until it gets there. `Ctrl+R` swaps on the next chunk instead.

**Broken source changes nothing.** The reason appears under the loop and whatever was last
evaluated keeps playing, because the app never hands the stage a score that would not build.

| Key | Effect |
| --- | --- |
| Any character | Type into the current loop |
| `←` `→` `↑` `↓` `Home` `End` | Move around its source |
| `Enter` | Break the line |
| `Ctrl+E` | Evaluate — in when the loop comes round |
| `Ctrl+R` | Evaluate — in now |
| `Ctrl+N` | A new loop, auto-named |
| `Ctrl+X` | Stop this loop |
| `Tab` | Comment it out, or back in |
| `Ctrl+P` | Play and pause everything |
| `?` | Help |
| `Ctrl+Q` | Quit |

| Option | Meaning |
| --- | --- |
| `--loop NAME=SOURCE` | A loop to open on, repeatable |

---

# Step sequencer

A step sequencer in a terminal, drawn with Drafter over
`TuningFork.Composer` (tuning_fork_composer).

**For composing by ear and by eye rather than by writing code.** Notes go on the grid with the
arrows, the mouse and the space bar; nothing is typed and nothing has to be learnt about
patterns, cycles or the DSL. `w` writes the tune out as ordinary source if you ever want it in
code, but you never have to.

```bash
mix tuning_fork.compose
```

```
Compose
96 bpm · 2 bars · 4/4 · a2 minor_pentatonic · gain 0.5
             1           2           3           4
▸ kick      [█] ·  ·  ·  █  ·  ·  ·  █  ·  ·  ·  █  ·  ·  ·
  snare      ·  ·  ·  ·  █  ·  ·  ·  ·  ·  ·  ·  █  ·  ·  ·
  hat        █  ·  █  ·  █  ·  █  ·  █  ·  █  ·  █  ·  █  ·
  bass       1  ·  ·  ·  1  ▬  ▬  ·  4  ·  ·  ·  3  ·  ·  ·
```

`▸` marks the row, `[ ]` the step. `█` a drum hit, a digit a scale degree, `▬` a note held
from earlier, `·` silence. Dimmed rows are muted.

## Mouse

| Gesture | Effect |
| --- | --- |
| Click a step | Place a note, and move the cursor there |
| Click a pitched step again | Walk it up the scale |
| Drag right from a note | Hold it over the steps you cross |
| Wheel over a step | Walk it up or down the scale |

## Keys

| Key | Effect |
| --- | --- |
| Arrows | Move the cursor |
| Space | Place a note, or take it away |
| `+` `-` | Walk a pitched note up and down the scale |
| `>` `<` | Hold a note one step longer or shorter |
| `m` | Mute this row |
| `c` | Empty this row |
| `a` `x` | Add a row, remove this row |
| `k` | Cycle kind: drum → pitched → sample |
| `i` | Cycle instrument |
| `p` | Play what is on screen |
| `w` | Write the source out |
| `q` | Quit |

## Options

```bash
mix tuning_fork.compose --bpm 120 --bars 4 --meter 3 --division 8
mix tuning_fork.compose --empty --out beat.exs
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--bpm N` | 96 | Tempo |
| `--bars N` | 2 | How many bars |
| `--meter N` | 4 | Beats to a bar — 3 is a waltz |
| `--division N` | 4 | Steps to a beat — 3 is triplets, 8 thirty-seconds |
| `--gain N` | 0.5 | Level per note, 0.0–1.0 |
| `--key NOTE` | a2 | Key, e.g. `c3` |
| `--scale NAME` | minor_pentatonic | `minor`, `major`, `dorian`, `blues`, … |
| `--name NAME` | song | Variable the written source binds to |
| `--empty` | off | Start with no tracks |
| `--out PATH` | song.exs | Where `w` writes |

## What `w` writes

Ordinary `TuningFork.Part` source, ending in a `Wav.write!`. Run it anywhere:

```bash
mix run song.exs      # writes song.wav
```

Nothing of this package appears in it.

## Playing

`p` starts, `p` again stops — only ever one at a time, and quitting stops it too.

What plays is a render of the grid as it was when you pressed, looping. Edits made while it
runs are not heard until you stop and start again.

| | |
| --- | --- |
| First play, 2 bars | ~200 ms |
| First play, 16 bars | ~550 ms |
| Play again, no edit | a few ms — the render is kept |
| Play again after an edit | re-rendered |
| Stop | a few ms, whatever the length |

`p` needs `tuning_fork_speaker`, which is an optional dependency. Without it the editor still
runs and still writes source — it just says so instead of playing.

## Using it from your own project

Rather than `cd`-ing here, add it as a dependency and the task comes with it:

```elixir
{:tuning_fork_drafter, "~> 0.1"}
```

Then `mix tuning_fork.compose` works from your project, and `--out` writes beside your code.

## Notes on Drafter

Facts that are not obvious from its docs, kept here because this app depends on them:

- Props go under `:props` — `Drafter.run(App, props: %{project: p})`. Anything at the top
  level of the options is silently ignored, so passing `project:` directly means `mount/1`
  gets `%{}` with no error anywhere
- `mount/1` receives props as a **map**, not a keyword list
- Mouse events are `{:mouse, %{type: type, x: x, y: y, button: _, mods: _}}` — `type`, not
  `action`, whatever `Drafter.Event.mouse/4` suggests
- `type` is `:mouse_down`, `:mouse_up`, `:move` or `:scroll`; `:scroll` also carries
  `:direction`
- `x` and `y` are **zero-based** from the top left
- Key events are `{:key, :q}`, `{:key, :left}`, `{:key, :+}` — the character as an atom
- `update/2` returns the new state, or `{:stop, reason}` to quit
- Widget helpers used here: `vertical/2`, `label/2`, `header/1`, `footer/1`
