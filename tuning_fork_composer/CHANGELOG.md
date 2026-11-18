# Changelog

## [Unreleased]

### Breaking changes

* None since 0.1.13.

### Added

* Sections: `TuningFork.Composer.add_section/4` gives a project named sections, each a
  length in bars and the tracks that sound in it. `sections/1` lists them,
  `total_bars/1` is the song's length, and `passes_at/2` is a track's on/off string
  across the whole song.
* `TuningFork.Composer.Bake.bake/3` renders a project to a song bundle: `mix.wav`, a WAV
  per stem, `score.mid` and the `song.json` that names them, all at one rate and
  channel count. `mix tuning_fork.bake` does the same from the JSON
  `TuningFork.Composer.Json.to_map/1` writes.
* `TuningFork.Composer.to_song/2` and `TuningFork.Composer.Song` describe a project as
  a `TuningFork.Song`: a stem per audible track and an entry per section.

## [0.1.12]

### Breaking changes

* None since 0.1.11.

## [0.1.11]

* Released alongside the family; no changes to this package.

## [0.1.10]

* Released alongside the family; no changes to this package.

## [0.1.9]

* Released alongside the family; no changes to this package.

## [0.1.8]

* Released alongside the family; no changes to this package.

## [0.1.7]

* Released alongside the family; no changes to this package.

## [0.1.6]

* Released alongside the family; no changes to this package.

## 0.1.5

* `Composer.to_score/2` takes `repeat: n`: the grid once, as it sounds on its `n`th repeat,
  with the tracks whose `:plays` say so.

## 0.1.4

* Version brought level with the rest of the family; nothing else changed.

## 0.1.3

* A `:kit` setting: `:synth` as before, or a drum machine name for its recordings and the
  General MIDI soundfonts, in the score and in the written source alike.
* A track's `:plays` says which repeats of the grid it sounds on, as a string of `x` and
  `.` cycled over the bars; `Composer.passes/2` resolves it.
* `epiano`, the electric piano, among the instruments.

## 0.1.1

* `Json.from_map/1` reads every note name it knows whether or not the atom exists yet.

## 0.1.0

First release.
