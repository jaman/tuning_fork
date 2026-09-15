# TuningFork

Sound synthesised on the BEAM. This repository holds the `tuning_fork` library and the
packages around it, each published to hex.pm on its own.

| Package | What | Hex |
| --- | --- | --- |
| [`tuning_fork`](tuning_fork) | Voices, scores, live patterns, Sonic Pi and Strudel spellings, MIDI files, OSC. Pure Elixir, no dependencies | `{:tuning_fork, "~> 0.1.4"}` |
| [`tuning_fork_speaker`](tuning_fork_speaker) | Playback through this machine's sound device (C, via miniaudio) | `{:tuning_fork_speaker, "~> 0.1.4"}` |
| [`tuning_fork_midi`](tuning_fork_midi) | MIDI devices: scores and live patterns out, a keyboard in (C, via minimidio) | `{:tuning_fork_midi, "~> 0.1.4"}` |
| [`tuning_fork_samples`](tuning_fork_samples) | Sonic Pi's 206 recordings by name, fetched as they play | `{:tuning_fork_samples, "~> 0.1.4"}` |
| [`tuning_fork_composer`](tuning_fork_composer) | A step sequencer as data, writing TuningFork source | `{:tuning_fork_composer, "~> 0.1.4"}` |
| [`tuning_fork_kino`](tuning_fork_kino) | Livebook: a streaming stage widget and five smart cells | `{:tuning_fork_kino, "~> 0.1.4"}` |
| [`tuning_fork_drafter`](tuning_fork_drafter) | Terminal front ends drawn with Drafter | from this repository |

Start with [`tuning_fork/README.md`](tuning_fork/README.md), or hear it first: the tour
notebook is one tune written three ways — a grid, Strudel's syntax, Sonic Pi's — on the
same recordings, and opens straight into Livebook.

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fjaman%2Ftuning_fork%2Fmain%2Ftuning_fork_kino%2Fnotebooks%2Fcomposer.livemd)

## Working from this repository

Each package is an ordinary Mix project in its own directory; `mix test`, `mix credo --strict`
and `mix docs` run inside each. Within the repository the packages depend on each other by
path, so an edit in `tuning_fork` is seen by the others at once.

## Thanks

Two projects shaped this library, and it plays their music as written:

* [Sonic Pi](https://sonic-pi.net) by Sam Aaron and contributors — `live_loop`, `play`,
  `sleep`, `sample`, `with_fx` and the rest of the vocabulary in `TuningFork.SonicPi`, the
  synth and effect names, and the 206 public-domain recordings `tuning_fork_samples` fetches.
* [Strudel](https://strudel.cc) by Felix Roos, Alex McLean and contributors, and
  [Tidal Cycles](https://tidalcycles.org) by Alex McLean before it — the pattern model, the
  mini-notation, the control names, the chord dictionaries and voicing rules, and the sound
  design in [superdough](https://github.com/tidalcycles/strudel/tree/main/packages/superdough)
  that `TuningFork.Kit` and the effects follow. The sample sets strudel.cc loads —
  [uzu-drumkit](https://github.com/tidalcycles/uzu-drumkit),
  [tidal-drum-machines](https://github.com/ritchse/tidal-drum-machines),
  [Dirt-Samples](https://github.com/tidalcycles/Dirt-Samples),
  [VCSL](https://github.com/sgossner/VCSL) by Versilian Studios, the
  [mridangam](https://github.com/yaxu/mrid) recordings and the piano from
  [dough-samples](https://github.com/felixroos/dough-samples) — are fetched from where they
  are published, under their own licences.

Also: [WebAudioFont](https://github.com/surikov/webaudiofont) by Sergey Surikov for the
General MIDI soundfonts behind `gm_` sounds; Jezar at Dreampoint for Freeverb, which the
reverb is; [miniaudio](https://miniaud.io) by David Reid in `tuning_fork_speaker` and
[minimidio](https://github.com/octetta/minimidio) by Joseph Stewart in `tuning_fork_midi`.

## Licence

MIT, see [LICENSE](LICENSE). Sonic Pi's recordings are CC0; the soundfonts and sample sets
fetched for Strudel pieces carry their own licences, listed where they are hosted.
