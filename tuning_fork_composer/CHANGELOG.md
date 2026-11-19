# Changelog

## [0.1.14]

### Breaking changes

* None since 0.1.13.

### Added

* Arrangements: `TuningFork.Composer.Arrangement` is a song as tracks of clips placed on
  bars, with named sections and markers. A clip (`Arrangement.Clip`) holds notes, drum
  steps, a pattern with pitches or chords, a Strudel chain, a Sonic Pi loop or a
  recording. A track (`Arrangement.Track`) has an instrument (a drum, a composer
  instrument, a `gm_` soundfont, `"sample:"` and a file, or a sample bank), a level, pan,
  reverb send, mute, solo and mono.
* `Arrangement.Render.stems/2` renders a stem per audible track, the whole song long, and
  `Arrangement.Bake.bake/3` writes the arrangement as a song bundle: the mix, the stems,
  the backing for `:playable` stems, `score.mid` at exact pitches and lengths, sections
  with their seconds, markers, and every stem's notes or hits by bar and beat.
* `Arrangement.Json` writes an arrangement as JSON (`"format": "tuning_fork.arrangement"`)
  and reads it back, reporting what is wrong and where. `mix tuning_fork.bake` bakes such
  a file as well as a grid composition.
* `Arrangement.Flatten.with_notes/1` rewrites steps, patterns and Strudel clips as the
  notes they play, for programs that only play notes.
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

## [0.1.13]

### Changed

* No changes in this package; released with the rest of the tuning_fork packages.

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
