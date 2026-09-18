# Changelog

## [0.1.10]

* A cell streams its stage's PCM to the page only while the page is listening — the
  player says so when ▶ listen starts and stops (`KinoTuningFork.Listening`) — rather than
  from the moment the stage starts, so a notebook with several stages open no longer pushes
  hundreds of kilobytes a second into a browser tab that is playing none of it.
* The MIDI cell leaves clock ticks out of what it sends the page, and sends the real-time
  messages (`start`, `stop`, `continue`) as one-element lists.

## 0.1.5

* The Compose cell plays the grid live on a stage of its own, repeat by repeat, with an
  edit landing at the next repeat, in place of rendering the piece to a file first.

## 0.1.4

* A **TF MIDI** cell: a keyboard in and heard, a pattern out with clock, a key strip lit for
  both directions, a log of every message; registered when `tuning_fork_midi` is installed.
* The tour notebook has a MIDI device section, and fetches `bwv971.mid` itself when opened
  away from the repository, as from the Run in Livebook badges the READMEs carry.

## 0.1.3

* `composer.livemd`'s Compose grid carries the same seven-section arrangement as the other
  two spellings, on the same recorded kit.
* The Compose cell has, per track, which bars it plays.

## 0.1.2

* `composer.livemd` is one tune written three ways — the Compose grid on a recorded kit, a
  TF Patterns cell in strudel.cc's own syntax, TF Loops — the live two taking it through an
  arrangement, plus a MIDI file next to it.
* The Compose cell has a Kit control.
* A TF Patterns cell fetches strudel.cc's default sample sets when it opens.
* A MIDI cell's relative path is taken from the notebook's directory.
* A stage widget whose stage was replaced stays on the page, silent, and says so.

## 0.1.0

First release.
