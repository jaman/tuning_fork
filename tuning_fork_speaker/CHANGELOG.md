# Changelog

## Unreleased

### Fixed

* Builds on Windows with the Visual Studio compiler through `Makefile.win`; miniaudio plays through WASAPI.

## [0.1.12]

### Changed

* The compiled native code is built into and loaded from `priv/native/<system architecture>`
  instead of `priv/`, so builds for macOS and Linux in one checkout no longer overwrite each
  other.

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

* `TuningFork.Listener` requires `:port`, and `:ip` picks the interface to listen on,
  default `{127, 0, 0, 1}`. `mix tuning_fork.listen` requires `--port` and takes `--ip`.
* Log lines are prefixed `tuning_fork:`.

## 0.1.5

* `TuningFork.Listener` and `mix tuning_fork.listen` — play raw PCM arriving on a TCP port
  through the speaker, one connection after another, dropping what arrives faster than it
  plays down to `:max_lag_ms`; the far end of `TuningFork.Sink.Tcp`.

## 0.1.4

* Version brought level with the rest of the family; nothing else changed.

## 0.1.3

* Version brought level with the rest of the family; nothing else changed.

## 0.1.0

First release.
