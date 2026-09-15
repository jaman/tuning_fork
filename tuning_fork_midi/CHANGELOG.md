# Changelog

## 0.1.3

* `TuningFork.Midi.Monitor`: both directions in one process for a front end — an input
  played and watched, an output a pattern or a tapped note goes out of, every event reported
  to subscribers.
* `Out.play/3` and `Out.pattern/3` take `to: pid` and report each message they send.
* Closing an input port no longer holds the port's lock while the backend thread is stopped,
  which could deadlock the VM when a message arrived at that moment.

## 0.1.0

First release.
