# Gaps and future desires

What TuningFork does not do, what it would cost to close each gap, and what would
have to be true before it was worth doing. None of it blocks the work already
agreed — a project file, a bake step, a bundle reader — which needs no new sound
sources at all.

Each item ends in a trigger: the observable event that should reopen the
decision. Until then, "no" is the answer, and it is a decision rather than an
oversight.

## The baseline

A gap is only a gap relative to something. Today, without a plugin host:

| Have | Where |
| --- | --- |
| Additive/subtractive/FM voices, envelopes, filters, curves | `TuningFork.Voice`, `Envelope`, `Filter`, `Curve` |
| A curated kit, drum machines, General MIDI soundfonts | `TuningFork.Kit`, `Gm`, `Gm.Fonts` |
| 206 Sonic Pi recordings, fetched as they play | `tuning_fork_samples` |
| Strudel's sample sets and sound design | `TuningFork.Strudel`, `Kit` |
| SFZ instruments (regions, one velocity layer, round robin) | `TuningFork.Sfz` |
| MT-32 playback via Munt | `tuning_fork_mt32` |
| Scores, MIDI files, MIDI devices, OSC | `TuningFork.Score`, `Midi`, `Osc` |
| Live patterns, Sonic Pi and Strudel spellings | `TuningFork.Pattern`, `SonicPi`, `Strudel` |
| A step sequencer as data, with a terminal editor | `tuning_fork_composer`, `tuning_fork_drafter` |
| Deterministic rendering, content-addressed cache, bakes | `TuningFork.Cache`, `Mix.Tasks.TuningFork.Render` |
| Sections and layers, cued from game state | `Cauldron.Audio.Music` |

The gaps below are all about **timbre**: third-party DSP, commercial sample
libraries, and the finishing tools (tuning, mastering) that a release needs.
Composition is not on this list, because it is not missing.

## 1. Bake stems in a DAW

**Cost:** none. **Payoff:** any sound, exactly.

When a piece needs a specific instrument, render that track in a DAW and import
the result. The bundle layout in [SONG_BUNDLES.md](SONG_BUNDLES.md) already
holds `stems/<name>.wav`; nothing in TuningFork or Cauldron needs to change.

This is the answer to most "we need VST" moments, and it is the answer the games
industry already uses: ship baked audio, not plugin graphs. Per-seat licences,
platform coverage and reproducible QA all point the same way.

**Trigger for revisiting:** the same sound being re-rendered by hand often
enough that the round trip becomes a tax.

## 2. Extend SFZ

**Cost:** small to medium. **Payoff:** acoustic and orchestral instruments from
freely licensed libraries.

`TuningFork.Sfz` reads `<control>`, `<global>`, `<master>`, `<group>` and
`<region>`, key and velocity ranges, one velocity layer per bank, round robins,
tuning, volume, loop points and switches. It does not read release triggers,
velocity crossfade, keyswitches or filters — the features that make a sampled
instrument feel played rather than triggered.

Growing it covers VCSL, Sonatina, Salamander and the like: the free end of the
sample-library world, in a text format, with no native code and no licence
questions. [VCSL](https://github.com/sgossner/VCSL) is already fetched by the
kit, so the pieces are in place.

**Trigger:** a piece led by an acoustic instrument, or a game that needs a
believable ensemble.

## 3. Hand-built voices

**Cost:** per voice, small. **Payoff:** a palette that is coherent, portable,
deterministic and entirely ours.

This is the Sonic Pi and Strudel model, and the reason both can run anywhere:
a fixed, curated set of sounds, designed rather than licensed. Every voice added
here also bakes exactly, which keeps the game path simple.

The honest limit: it covers "sounds we thought of". It does not cover a client
asking for a specific commercial instrument, and it does not cover a sample
library with 40 GB of articulations.

**Trigger:** none needed. This is the default way to close a gap, and should
happen whenever a piece needs a sound that the kit lacks.

## 4. LV2 or CLAP, headless, through a sidecar NIF

**Cost:** large. **Payoff:** third-party DSP — commercial instruments, effect
character, mastering chains.

Feasible; see the notes below for why the earlier "no VST on the BEAM" was too
strong. The shape that works:

- a NIF that loads a plugin and owns the audio thread it creates — never a
  scheduler thread;
- pre-allocated buffers and a lock-free handoff, so a block is never late;
- parameter changes and note events read from a snapshot at block boundaries,
  so everything from Elixir is block-granular;
- no plugin GUI. A generic parameter surface is better for a terminal anyway,
  and it removes the largest piece of any real host;
- authoring side only. Plugins never enter a shipped build; their audio is
  baked like everything else.

Prefer **CLAP** (C ABI, MIT, no COM) or **LV2** (ISC, text metadata) over VST3
(C++ interoperability, for no extra reach). Keep it a separate package, e.g.
`tuning_fork_clap`, so the core stays dependency-free.

What it does not fix: plugin state is an opaque blob, and plugins change. A
project that names a plugin does not guarantee the same audio in a year. That is
the same reason `.flp` and `.mmp` do not travel, and it is a product problem
rather than a runtime one.

**Trigger:** the tool must open other people's projects, or users arrive
expecting commercial instruments.

## 5. Deliberately out of scope

| Not doing | Why |
| --- | --- |
| VST2 | Discontinued by Steinberg in 2018; nothing new should target it |
| AAX | Pro Tools only, proprietary, wrapped |
| AU / AUv3 | Apple only; the terminal bakes, it does not need host integration |
| Plugin GUIs | Native windows in a TUI; a generic parameter surface is better here |
| Plugin hosting in games | Per-seat licences, console and mobile coverage, unreproducible state |
| Importing `.flp`, `.mmp`, `.ardour` | Fidelity tar pit. MIDI in and out is the useful subset |
| Sample-library management | A player, not a catalogue. Register the instruments a project uses |

## What is not a gap

- **Composition.** Patterns, sections, layers, cues, MIDI and OSC. Plugins sit
  downstream of all of it.
- **Determinism.** Voices are deterministic, so a render is the sound and the
  cache fingerprint means something. Nothing in a plugin host preserves that.
- **Microtuning.** Commercial plugins overwhelmingly assume 12-TET MIDI; MPE and
  microtuning support is patchy and per-plugin. `TuningFork.Scale`, `Chord` and
  `Notes` are more expressive than what a plugin host would add, not less.

## Adjacent: an SFX editor (open question)

Raised 2026-10-23: Cauldron targets games, so should there be a sound-effect
editor, and should it live in Cauldron rather than outside it?

The guess is right about the workflow and wrong about one layer. An SFX editor
is not a wave editor. What it edits is the game's **event vocabulary** — the
mapping from `:brick` or `{:explosion, {x, y}}` to a voice, its variants, its
priority, its attenuation with distance, and how many of it may sound at once.
That vocabulary is a Cauldron concept (`Cauldron.Audio` takes exactly that
mapping from the game), and no external tool can know it.

So the split that keeps the layering intact:

| Layer | Belongs to | Why |
| --- | --- | --- |
| Sound material and parameters | `tuning_fork` (`Voice`, `Kit`, `Sfz`) | It already is the synthesis model, and it bakes |
| Event → sound, mixing, voice budget, spatialisation | `cauldron_core` (`Cauldron.Audio`) | Game semantics; the game already names its events |
| The editor | `cauldron_sfx`, over `drafter` | It reads the game's events and writes the game's asset |

A `mix cauldron.sfx` task (or a `cauldron_sfx` package depending on
`tuning_fork_drafter`) satisfies "part of the game creation flow" without
putting Drafter into the core or asking TuningFork to learn about games. It
would: list a game's events, audition each in isolation and over a scene, shape
variants and randomisation, check the voice budget, and bake a bank.

That bank is the same shape as a song bundle — PCM plus a manifest, read by
`tuning_fork` alone — so there is one bake pipeline and one play-only format for
music and sound alike, which is the property worth protecting.

**Built:** the bank is `Cauldron.SFX` in `cauldron_core` — events, variants, recipes, the
`sounds/1` function `Cauldron.Audio` plays — and the editor is `cauldron_sfx`, opened with
`mix cauldron.sfx`. A game loads the bank and plays it; nothing in the game needs the
editor. Baking a bank to PCM is not built: a voice is deterministic, so a game synthesises
the effect rather than reading a file, and a bank that has to ship as audio can be rendered
with `TuningFork.Voice` the same way a song bundle is.

## Built next, outside this document

The project file, the bake step and the bundle reader described in
[SONG_BUNDLES.md](SONG_BUNDLES.md) are in: `song.json` read and written by
`TuningFork.Song`, `mix tuning_fork.bake` rendering a composition into a bundle,
and `TuningFork.Song.to_piece/2` turning one into the spec
`Cauldron.Audio.Music.piece/3` takes. None of the gaps above was a prerequisite,
and none of them is closed by it.
