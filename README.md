# TuningFork

Sound synthesised on the BEAM. This repository holds the `tuning_fork` library and the
packages around it, each published to hex.pm on its own.

| Package | What | Hex |
| --- | --- | --- |
| [`tuning_fork`](tuning_fork) | Voices, scores, live patterns, Sonic Pi and Strudel spellings, MIDI files, OSC. Pure Elixir, no dependencies | `{:tuning_fork, "~> 0.1"}` |
| [`tuning_fork_speaker`](tuning_fork_speaker) | Playback through this machine's sound device (C, via miniaudio) | `{:tuning_fork_speaker, "~> 0.1"}` |
| [`tuning_fork_midi`](tuning_fork_midi) | MIDI devices: scores and live patterns out, a keyboard in (C, via minimidio) | `{:tuning_fork_midi, "~> 0.1"}` |
| [`tuning_fork_samples`](tuning_fork_samples) | Sonic Pi's 206 recordings by name, fetched as they play | `{:tuning_fork_samples, "~> 0.1"}` |
| [`tuning_fork_composer`](tuning_fork_composer) | A step sequencer as data, writing TuningFork source | `{:tuning_fork_composer, "~> 0.1"}` |
| [`tuning_fork_kino`](tuning_fork_kino) | Livebook: a streaming stage widget and four smart cells | `{:tuning_fork_kino, "~> 0.1"}` |
| [`tuning_fork_drafter`](tuning_fork_drafter) | Terminal front ends drawn with Drafter | from this repository |

Start with [`tuning_fork/README.md`](tuning_fork/README.md).

## Working from this repository

Each package is an ordinary Mix project in its own directory; `mix test`, `mix credo --strict`
and `mix docs` run inside each. Within the repository the packages depend on each other by
path, so an edit in `tuning_fork` is seen by the others at once.

## Licence

MIT, see [LICENSE](LICENSE). Sonic Pi's recordings are CC0; the soundfonts and sample sets
fetched for Strudel pieces carry their own licences, listed where they are hosted.
