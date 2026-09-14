# Changelog

## 0.1.1

* `bank/2` keeps the bank name on each event; the kit plays the recording registered as
  `bank_sound` when the bank has it, and its own drum until then. Before, a name in
  `TuningFork.Kit.banks/0` never reached the recordings.
* `struct/2` keeps every note sounding at a structural step, so a voiced chord under
  `struct` sounds whole.
* `use_synth` takes a sound name — `use_synth "gm_epiano1"` — played at each note through
  the kit. `TuningFork.Kit.known?/1` says which names qualify.
* A sample file whose name has a space in it is fetched.
* A step whose edge fell a rounding error inside a query span could be reported twice;
  `Pattern.query/2` leaves such slivers out.

## 0.1.0

First release.
