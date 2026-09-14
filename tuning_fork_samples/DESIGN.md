# TuningForkSamples design

## TuningFork.Samples

The 206 recordings are Sonic Pi's. Their names are compiled into `TuningFork.Samples.Names`
and each is registered with `TuningFork.Sample.Bank` as a URL into Sonic Pi's repository at
a fixed release tag, so the package itself is a few kilobytes and a recording is fetched
through `TuningFork.Sample.Fetch` and decoded by `TuningFork.Flac` the first time it is
played; the 34 MB never ship in the package, which keeps it within what hex.pm accepts.
`prefetch/0` warms the whole bank for a machine that will be offline. The names are Sonic
Pi's, so any Sonic Pi listing applies, and `families/0` groups them by the prefix before the
first underscore. Every recording is Creative Commons Zero; `priv/SOURCES.md` is Sonic Pi's
own list of where each came from on freesound.org, and of the sets donated by Uwe Zahn
(Arovane) and The Black Dog.

Registration with `TuningFork.Sample.Bank` happens when the application starts, which is
what lets `TuningFork.Kit`, a Strudel `s("bd_haus")` and Sonic Pi's `sample :bd_haus` find
them by name with nothing else configured. A pitched recording plays at its own speed unless
the voice is told its root, and an index after the name (`bass_hit_c:7`) is read as semitones
up, as it is for a synthesised drum.
