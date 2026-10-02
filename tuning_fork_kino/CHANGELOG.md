# Changelog

## [Unreleased]

### Breaking changes

* `KinoTuningFork.MidiMonitorCell` (TF MIDI) and `KinoTuningFork.MidiCell` keep a saved
  field whose value is `false` or `nil`; only a field missing from the saved attributes
  takes its default. A notebook saved with **Clock** off opens with clock off — turn it on
  in the cell where the device needs it.
* 1.0.0 marks the API as stable.

## [0.1.11]

* The tour notebook's TF MIDI cell opens MIDI input 0 as well as output 0.

## [0.1.10]

* A cell streams its stage's PCM to the page only while the page is listening — the
  player says so when ▶ listen starts and stops (`KinoTuningFork.Listening`) — rather than
  from the moment the stage starts, so a notebook with several stages open no longer pushes
  hundreds of kilobytes a second into a browser tab that is playing none of it.
* The MIDI cell leaves clock ticks out of what it sends the page.

## [0.1.9]

* The MIDI cell sends the real-time messages (`start`, `stop`, `continue`) to the page as
  one-element lists, in its log and as they arrive.
* The notebooks' setup cells ask for `~> 0.1` of each package.
* The tour notebook's TF MIDI cell is saved with a pattern, a voice, output 0 and clock on.

## [0.1.8]

* `KinoTuningFork.MidiMonitorCell.page_state/1` gives the monitor's state as the page takes
  it: the ports and the last twelve events as lists, the voice left out. The TF MIDI cell
  sends the page this.
* The tour notebook's setup cell installs `tuning_fork_midi`, which the TF MIDI cell needs.

## [0.1.7]

* Released alongside the family; no changes to this package.

## [0.1.6]

* `composer.livemd` is saved with each smart cell's generated source.
* The README asks for `{:tuning_fork_kino, "~> 0.1"}`.

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
