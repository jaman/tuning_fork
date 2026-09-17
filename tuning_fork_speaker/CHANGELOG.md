# Changelog

## 0.1.5

* `TuningFork.Listener` and `mix tuning_fork.listen` — play raw PCM arriving on a TCP port
  through the speaker, one connection after another, dropping what arrives faster than it
  plays down to `:max_lag_ms`; the far end of `TuningFork.Sink.Tcp`. `:port` is required
  and `:ip` (`--ip`) picks the interface, loopback by default.

## 0.1.4

* Version brought level with the rest of the family; nothing else changed.

## 0.1.3

* Version brought level with the rest of the family; nothing else changed.

## 0.1.0

First release.
