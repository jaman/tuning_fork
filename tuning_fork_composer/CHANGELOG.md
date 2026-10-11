# Changelog

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
