# TuningFork design

How the library is put together and why each module behaves as it does. The `@moduledoc` and
`@doc` in `lib/` say what each function does and how to call it; this document holds the
design behind them, organised by module.

## TuningFork

A sound is described rather than recorded: `TuningFork.Voice` is a waveform, a pitch, an
envelope and a filter, and `TuningFork.Stage` mixes whatever is sounding into one stream. The
library is pure Elixir with no dependencies, no C compiler and no audio device required.

Where the sound goes is decided by a `TuningFork.Sink`, the output backend. Any module
exporting `open/1`, `write/2` and `close/1` is a sink:

* `TuningFork.Sink.Silent` is the default and discards everything.
* `TuningFork.Sink.Collect` sends samples to a process, for a test that asserts on them.
* `TuningFork.Sink.Buffer` keeps everything written, for recording.
* `TuningFork.Sink.Speaker` plays through the machine. It lives in the separate
  `tuning_fork_speaker` package.

`TuningFork.Score.render/3` returns PCM without opening a device.

Output is stereo unless a `:channels` of 1 says otherwise. Voices are synthesised in mono and
panned where they are placed.

`TuningFork.available?/0` is false where `tuning_fork_speaker` is not installed or its device
will not open. A stage whose sink will not open falls back to silence rather than refusing to
start, so an application never has to branch on whether sound is possible.

`TuningFork.start_stage/1` starts the stage under the library's own `DynamicSupervisor`
rather than linking it to the caller, so a stage that dies does not take the calling process
with it.

## TuningFork.Cache

Rendered audio is kept on disk under `$XDG_STATE_HOME/tuning_fork`, falling back to
`~/.local/state/tuning_fork`. A relative `$XDG_STATE_HOME` is ignored.

A stored file is named for its key and for a fingerprint the caller supplies. A fingerprint that
changes when the code rendering the audio changes is what stops a stale file being read back.
`fingerprint/1` hashes the `vsn` of the given module together with those of `TuningFork.Voice`
and `TuningFork.Mixer`, so audio rendered by an older version of the renderer is not read back
by a newer one.

Storing is best-effort: a directory that cannot be written is logged at debug level and the
audio is returned anyway, so a caller never has to handle a cache failure.

## TuningFork.Chord

A chord name is a root, an optional accidental, and a quality: `C`, `Eb`, `F#m7`, `Bb^9`. The
root is read at octave 4, so `C` is middle C at 60, and `octave/2` moves it.

A name the module does not know gives `[]` rather than raising, so a chord typed wrong falls
silent instead of stopping the music.

The qualities `notes/1` accepts:

| | |
| --- | --- |
| nothing, `M`, `maj` | major triad |
| `m`, `min`, `-` | minor triad |
| `+`, `aug` | augmented |
| `o`, `dim` | diminished |
| `7` | dominant seventh |
| `^7`, `maj7`, `M7` | major seventh |
| `m7`, `min7`, `-7` | minor seventh |
| `o7`, `dim7` | diminished seventh |
| `m7b5`, `ø` | half diminished |
| `6`, `m6` | sixths |
| `9`, `^9`, `m9` | ninths |
| `sus2`, `sus4` | suspended |
| `5` | the bare fifth |

## TuningFork.Curve

A curve is a multiplier over the field it is attached to, never an absolute value. A freq curve
of `2.0` is an octave up on whatever note it is used with.

Reading before the first breakpoint or after the last gives that breakpoint's value, so a curve
never has to state what happens outside its own range.

`simplify/2` drops interior points one at a time, each time whichever point its two neighbours
already predict most closely, so peaks survive and points sitting on a straight line do not. It
keeps at least two breakpoints: a curve of one point is a value that does not move, which is
`hold/1`, not something thinning can arrive at.

## TuningFork.Envelope

`duration/1` is attack, decay, hold and release together, and it is what decides how many
samples a voice renders. When `sustain` is 0.0 it is attack and decay alone: the level is
zero from the end of the decay on, so hold and release would be silence, and a piano chord
held for four cycles must not cost four cycles of synthesis.

`:curve` bends the decay. A curve of 1.0 is a straight line; above 1.0 the level falls away
quickly and then trails.

## TuningFork.Filter

The filter is what makes a saw sound like an instrument rather than a buzz. `TuningFork.Voice`'s
`:cutoff` is a one-pole smoother of 6 dB an octave with no resonance, which barely dents a
sawtooth, whose own harmonics already fall at 6 dB an octave.

### The two models

`:ladder` is four one-pole stages with the output fed back into the input, each stage
saturating: the transistor ladder. Because the feedback is subtracted from the input, resonance
makes it quieter rather than louder, and because every stage saturates, it cannot run away
however hard it is driven. `:q` is scaled down by `feedback/1` and the level put back by
`makeup/1`.

`:svf` is a topology-preserving state-variable filter: cleaner, no saturation, and the only
model that can be a highpass or a bandpass. A `:highpass` or `:bandpass` is therefore always
`:svf`. It has no resonance compensation, so a high `:q` on an `:svf` really is much louder.

### Resonance, drive and makeup

`feedback/1` scales `:q` by 0.13 and holds it at 8, so the numbers it takes are the ones
Strudel's `resonance` takes: a `:q` of 9 is a squelch, not a siren. A filter asked for a `:q` of
40 is the same as one asked for 62; both are as resonant as it goes.

`:drive` is an exponent, so 0.0 is unity and the default 0.69 is very nearly 2. The output is
divided by the same number in `makeup/1`, so driving harder saturates harder at the same volume
rather than simply being louder.

`makeup/1` does two things at once: `1 / drive` takes back the gain the drive put in, and
`1 + k` puts back the level a ladder loses as it resonates. That second part is held at 1.75 so
a filter at full resonance does not run away.

For the `:svf`, a bandpass or a resonant highpass has a gain of about `q` at its corner, so at
any real resonance it arrives over full scale and is clipped square. The output is divided by
`q` to leave the shape and take away the loudness. The lowpass is left alone: `makeup/1`
handles the ladder, and a flat `:svf` lowpass has a gain of one already.

The ladder's drive, feedback and makeup gain depend only on the filter, so `start/1` works
them out once and carries them in the state `step/5` threads through, rather than taking
two exponentials per sample. The state is opaque for that reason: its shape is the filter's
business.

### The sweep

With an `:envelope` and an `:amount`, the cutoff starts at `:hz`, rises to `amount` octaves
above it as the envelope opens, and falls back as it closes. An `:amount` of 3 with a short
decay is the classic acid sound:

    TuningFork.Filter.new(hz: 300, q: 9.0,
      envelope: TuningFork.Envelope.new(attack: 0.002, decay: 0.18, sustain: 0.1),
      amount: 3.5)

### Stability

Neither model blows up as the cutoff sweeps, the way a naive digital filter does when its
coefficients change mid-note: the ladder saturates and the `:svf` is a topology-preserving
transform. The cutoff is held between 20 Hz and just under Nyquist whatever it is asked for.

## TuningFork.Gm

A MIDI file names its instruments as program numbers, and General MIDI says what the numbers
mean: 0 is a grand piano, 33 an electric bass, 57 a trumpet. `Gm` maps those numbers onto
voices built from the waveforms, envelopes and filters `TuningFork.Voice` has, one family of
settings per group of programs, so an arbitrary file comes out as an arrangement of
distinguishable parts rather than as one voice playing everything.

Every voice is derived from a `base` voice the caller supplies, so its gain, pan and filter
defaults carry through. The result is an ordinary `TuningFork.Voice` and can be overridden:

    %{Gm.for_program(0, base) | shape: :sine}

These voices are what `gm_*` names play while their soundfont is still arriving, or on a
machine that cannot decode one. A `:struck` voice decays over 1.2 seconds to nothing and
ignores how long the note is held,
which is what a hammer on a string does; every other family holds at its sustain level for
the note and releases after.

The families are `:struck` (piano and tuned percussion), `:organ`, `:guitar`, `:bass`,
`:strings`, `:brass`, `:reed`, `:pipe`, `:lead` and `:pad`. `:other` covers programs 96 to
127, the sound effects, and leaves the base voice unchanged.

The drum kit is entirely filtered noise: low-passed for drums and toms, high-passed for hats
and cymbals, and through both for snares. `score/2`'s `:gain` default of 0.2 is a per-note
level; dense music needs less.

## TuningFork.Midi

### What the conversion keeps and drops

* Tempo changes are kept, as the score's tempo map.
* Note lengths are kept, as envelope decay, rounded to `:quantize`.
* Velocity becomes gain, scaled against the synth's own.
* Pitch bend is read two ways. Whatever the wheel is at when a note starts multiplies that
  note's frequency; a bend that moves while the note sounds becomes a `TuningFork.Curve`
  measured against that starting value.
* Instruments are not chosen here. A program change is a number, and `:synths` says what it
  plays.
* Control changes other than pitch bend are parsed and then dropped.
* Aftertouch is dropped at parse time.

### Naming the instruments

`:synths` maps a channel to a voice. `:drums` maps a note number to a voice, and applies on a
percussion channel, where a note number names a drum rather than a pitch. `:default` is what
anything unclaimed is played with.

    to_score(midi,
      synths: %{0 => lead, 2 => bass},
      drums: %{36 => kick, 38 => snare, 42 => hat},
      default: pad
    )

### Which channel the drums are on

`:drum_channels` defaults to `[9]`: channel 10 counted from zero, the General MIDI
convention. Files that ignore the convention, such as a library of loops that writes
everything on channel 1, need it stated:

    to_score(midi, drum_channels: [0], drums: %{36 => kick, 38 => snare, 46 => hat})

`:auto` guesses instead. Channel 9 is always included. Another channel is taken as percussion
only when all three of these hold:

* no program change anywhere on that channel
* every note it plays is between 27 and 87, the General MIDI percussion range
* at least half its distinct note numbers are between 35 and 59, the core of a kit

Percussion played entirely above 59 (congas, bongos, timbales) is not found by the guess,
because those numbers are also the middle of a keyboard. Such a file needs `:drum_channels`
said outright.

### Note lengths and the render cache

`TuningFork.Score` keys its synthesis cache on the voice, so every distinct note length is a
separate render. `:quantize` rounds lengths to a grid, 10 ms by default, which collapses a
performance's hundreds of distinct lengths into tens. `nil` turns it off and is slow.

### Encoding

`encode/2` writes format 0: one track, 480 ticks a beat. A note becomes a note on and a note
off, the gap between them being how long the voice sounds; a voice's pitch becomes the
nearest semitone and its gain becomes velocity. What a synthesised voice is does not survive:
a MIDI file carries notes, not instruments. Reading one back gives the notes, and `to_score/2`
is where the sounds are named again.

A MIDI delta time is seven bits a byte, with the top bit set on every byte but the last.

## TuningFork.Mixer

Everything works on signed 16-bit little-endian PCM. Buffers of different lengths mix to the
length of the longest.

A sample is one 16-bit number. A frame is one sample per channel, so in stereo a frame is two
samples and four bytes. `mix/2`, `scale/2`, `loudness/1`, `peak/1`, `clipped/1` and
`normalise/3` work a sample at a time and take no channel count. `silence/2`, `take/3`,
`mix_at/4` and `pan/3` measure in frames and take one, defaulting to 2.

`fold/3` is what closes a rendered loop without a join: a note or a reverb tail still sounding
at the end is heard at the beginning of the next time round.

`pan/3` is constant power: the two channels are the cosine and sine of the same angle, so a
centred sound sits about 3 dB below its mono render and a pan sweep does not dip in the
middle.

Mixing sums and then clamps, and the clamp leaves no other trace: a mix that ran over comes
back merely loud. More than a handful of samples counted by `clipped/1` means the parts need
less gain before rendering; normalising afterwards scales the flattened peaks down rather than
restoring them. `soft_clip/2` bends loud samples towards full scale instead, so a mix that ran
over comes back loud rather than square; a lower threshold rounds more of the signal and
sounds more compressed, and 1.0 is the hard clamp `mix/1` already does.

## TuningFork.Notes

A note name is an atom: a letter `a` to `g`, an optional `s` for sharp or `b` for flat, then
an octave, which may be negative. `:a4` is 440 Hz. A number is taken as a frequency in Hz and
passed through unchanged. `scales/0` and `chords/0` list the names that can be asked for;
anything else raises.

`semitone/1` accepts a string that has never been an atom, so a name read from a file or
typed into an editor resolves without `String.to_atom/1`. `name_of/1` always uses sharps, so
a flat comes back as the sharp that sounds the same.

## TuningFork.Osc

A message is an address, a type tag string, and the arguments themselves, each padded to a
multiple of four bytes. Everything on the wire sits on a four-byte boundary, so what follows a
value starts after its padding rather than straight after its bytes.

| Elixir | Tag | |
| --- | --- | --- |
| integer | `i` | 32-bit |
| float | `f` | 32-bit |
| binary | `s` | a string |
| `{:blob, bytes}` | `b` | arbitrary bytes |
| `true` `false` `nil` | `T` `F` `N` | no argument bytes at all |
| `{:int64, n}` | `h` | 64-bit |
| `{:double, f}` | `d` | 64-bit |

`bundle/2` puts messages under one time tag, so everything in it is meant to take effect
together. `:now` is the tag every receiver treats as immediately.

`decode/1` returns `{:error, :not_a_message}` rather than raising, so a stray packet on the
socket is reported rather than crashing the reader. The module is only the bytes;
`TuningFork.Osc.Client` is the socket.

## TuningFork.Osc.Client

OSC is UDP, and `:gen_udp` comes with the runtime, so the client needs no dependency and no
native code. The default port, 57120, is SuperCollider's.

`:listen` binds a port and sends what arrives to the owner process as
`{:osc, address, args, from}`:

    {:ok, client} = Osc.Client.start_link(listen: 57_121, owner: self())

    receive do
      {:osc, "/tempo", [bpm], _from} -> Stage.pattern_cps(cps_of(bpm))
    end

A packet that is not a message this understands is dropped rather than delivered, so a stray
one on a shared port cannot take the reader down.

## TuningFork.Osc.Out

Each note becomes one message when its moment arrives. Nothing is synthesised here: whatever
is listening makes the sound. The default is `/play` with the frequency in hertz, the gain,
how long the note sounds in seconds, and the pan:

    "/play", [440.0, 0.8, 0.35, 0.0]

There is no OSC convention for notes; every receiver has its own, so `:address` and `:shape`
are how a different one is met. `messages/2` gives what would be sent without sending it.

Every message is timed against one monotonic clock reading taken at the start, so a long
piece does not drift. Stopping sends the `:hush` address so the far end is not left sounding.

## TuningFork.Rand

A generator is a value, not a process. Every function takes one and returns the next
alongside its result, so the caller threads it through. The same seed gives the same sequence
on any node and in any process. The generator is a linear congruential one with modulus 2^31.

## TuningFork.Reverb

The reverb is Freeverb: eight comb filters into four allpasses per channel, with Jezar's
delay lengths scaled to the sample rate, the right channel's lines 23 samples longer than
the left's so the two sides decorrelate, damping of 0.4 in the comb feedback, an input gain
of 0.015 and a wet gain of 0.5. The state carries between calls, so a chunk of audio handed in
leaves a tail that comes back in the chunks after it. That is what makes it a room rather
than an echo: feed it silence and it keeps ringing until the room has died away.

A comb filter is a delay fed back on itself: one hit becomes a run of repeats a fixed time
apart. Eight of them at lengths that share no common factor give repeats that never line up,
which is what turns a stutter into a wash. The allpasses that follow leave the tone alone and
only smear the timing, so the wash stops sounding like separate delays.

`size` is how long the room rings, in seconds to silence, as Strudel's `roomsize` is: the
comb feedback is `exp(-6.9 × 0.03 / seconds)`, the gain that brings a 30 ms comb down 60 dB
in that time, held between 0.1 and 10 seconds. A `mix` of zero returns the input untouched
and does not disturb the state, so a pattern that asks for no room costs nothing. Stereo
goes through a left and a right room; mono through the left.

Each delay line is a `:queue`: the oldest sample comes off the front and the new one goes on
the back, amortised constant time with no copying, where a functional array copies part of
its tree on every write. The state stays a value — two players never share a room — and the
output is sample-for-sample what it was.

## TuningFork.Ring

An index past the end wraps to the start, and a negative one counts back from the end, so a
counter that only ever climbs still gives a note. With `TuningFork.Tick.tick/1` this is how a
line walks through a set of notes a round at a time rather than repeating one:

    part(bpm: 120, synth: Kit.voice(%{note: "c2", shape: :saw}, 0.4))
    |> play(Ring.at(~w(c2 e2 g2 a2)a, tick()), 4)

## TuningFork.Scale

A degree is a step along the scale, not a semitone. Degree 0 is the root, 1 the next note up,
and a degree past the end of the scale carries on into the octave above: degree 7 of a
seven-note scale is the root an octave up, and degree 9 is the third above that. Negative
degrees go down the same way.

`"g:minor"` is a root and a scale. The root may carry an octave, as in `"g2:minor"`, and
without one it is octave 3, so `"g:minor"` starts at g3. Sharps are `s` and flats are `b`:
`fs`, `eb`. The scale name may be left off, in which case it is `:major`.

## TuningFork.Pattern

Patterns of events over cycles, in the style of TidalCycles and Strudel. A pattern is asked
about a stretch of time and answers with the events in it:

    TuningFork.Pattern.query(pattern, {0.0, 0.25})
    [%{whole: {0.0, 0.5}, part: {0.0, 0.25}, value: :bd}]

Values are whatever was put in: atoms, maps, numbers. Nothing in the module knows about
frequencies or synthesis.

### Cycles

Time is counted in cycles. A cycle is one turn of the loop; how many seconds that is gets
decided at playback. Cycle numbers count up from zero and keep counting, and a pattern is a
function of that number, so asking about cycle 97 gives cycle 97's events whether or not
cycles 0 to 96 were ever played.

Every combinator returns a one-cycle-long pattern, so `fast(p, 3)` stacks beside a pattern of
four without either being rescaled.

### Events

`query/2` returns a list of `%{whole: span | nil, part: span, value: term}`. `whole` is where
the event sits as written and is `nil` for a continuous value; `part` is the portion of it the
query covers; `value` is what it is.

A query that cuts across an event returns a fragment: the same `whole`, a shortened `part`.
`onset?/1` tells a note beginning from one already sounding:

    query(pure(:x), {0.0, 0.5})   whole {0.0, 1.0}, part {0.0, 0.5}, onset? true
    query(pure(:x), {0.5, 1.0})   whole {0.0, 1.0}, part {0.5, 1.0}, onset? false

The span end is exclusive, so querying `{0.0, 1.0}` and then `{1.0, 2.0}` reports each event
once. A zero-width span samples continuous patterns and reports nothing discrete.

### The functions, grouped

| | |
| --- | --- |
| `pure/1`, `silence/0`, `run/1`, `binary/1` | one value a cycle, nothing, counting, bits |
| `fastcat/1`, `slowcat/1`, `stack/1` | in a cycle, a cycle each, all at once |
| `arrange/1`, `polymeter/2` | cycles each in turn, several metres at once |
| `fast/2`, `slow/2`, `shift/2`, `rev/1`, `palindrome/1` | move it about |
| `zoom/3`, `linger/2`, `ribbon/3`, `clip/2` | play a part of it, or hold it |
| `iter/2`, `iter_back/2`, `swing/2`, `swing_by/3` | shift it on as it goes |
| `every/3`, `first_of/3`, `last_of/3`, `when_cycle/3` | change it on some cycles |
| `chunk/3`, `chunk_back/3`, `fast_chunk/3`, `inside/3`, `outside/3` | change part of it |
| `off/3`, `superimpose/2`, `layer/2`, `stut/3`, `echo_with/4` | lay copies over it |
| `jux` (in `TuningFork.Pattern.Control`) | left as written, right changed |
| `euclid/3`, `euclid_rot/4`, `euclid_legato/3`, `bjorklund/2` | evenly spread hits |
| `degrade/3`, `undegrade/2`, `filter_events/2` | take events away |
| `sometimes/3`, `often/3`, `rarely/3`, `always/2`, `never/2` | change some of them |
| `some_cycles/3`, `some_cycles_by/4` | change some whole cycles |
| `sine/0`, `cosine/0`, `saw/0`, `isaw/0`, `tri/0`, `square/0` | values at every instant |
| `rand/1`, `irand/2`, `brand/1`, `choose/2`, `wchoose/2` | values chosen at every instant |
| `segment/2`, `range/3`, `with_value/2` | shape and rescale |
| `add/2`, `sub/2`, `mul/2`, `divide/2` | arithmetic on the values |
| `squeeze/2`, `squeeze_values/2`, `arp/2` | fit a pattern inside events, spread a chord out |
| `pick/2`, `invert/1`, `perlin/1` | choose between patterns, flip, drift |

### Steps

A cycle is one reference point and a step is the other. `steps/1` is how many a pattern is
counted as having: three for `fastcat([:a, :b, :c])`, and four for `"a [b c] d e"`, where the
bracket is one step however much is inside it.

On its own the count changes nothing about what a pattern plays. It is what the stepwise
functions read: `stepcat/1` gives each pattern room in proportion to it, and `pace/2` plays a
pattern at so many steps a cycle whatever it was written as. Two patterns paced the same run at
the same speed, which is what makes a ten-step phrase and an eighteen-step one line up.

| | |
| --- | --- |
| `stepcat/1` | end to end, each given room in proportion to its steps |
| `pace/2` | play at so many steps a cycle, whatever it was written as |
| `expand/2`, `contract/2`, `extend/2` | count it as more or fewer, and play it over |
| `take/2`, `drop/2` | the first or last so many steps |
| `shrink/2`, `grow/2` | wear it down or build it up, a step a cycle |
| `zip/1`, `tour/2` | one step from each in turn, each variation in turn |

Where `fastcat/1` gives every pattern the same slice of the cycle whatever is in it,
`stepcat/1` gives a three-step pattern three times the room of a one-step one, so the steps
come out the same length however they were grouped. `expand/2` on its own does nothing
audible; under `stepcat/1` the pattern takes `factor` times the room, and under `pace/2` it
runs `factor` times slower. `extend/2` is `fast/2` and `expand/2` together, which is what
makes a repeated phrase take proportionally more room in a `stepcat/1` rather than being
squeezed. `shrink/2` and `grow/2` give a phrase that unravels over several cycles rather than
repeating.

`fast/2` carries the step count through rather than scaling it: `fastcat/1` sets its own
afterwards, and `extend/2` relies on speeding up and re-counting being two separate things.

`stepalt/1` takes a step from each group in turn, each group offering a different pattern each
time round: a group of two beside a group of three takes six passes to come back to where it
started, and the whole thing is `stepcat/1`ed into one pattern.

### Combining values

`add/2`, `sub/2`, `mul/2` and `divide/2` keep the left pattern's timing and read the right one
at each event's start, so the left decides when things happen and the right only says by how
much. Where the values are control maps rather than numbers, every key they share is combined
and the rest are kept, so `add(pattern, %{note: 12})` transposes without disturbing anything
else. Dividing by zero leaves the value as it was.

`app_left/3` is the general form, and the one Strudel calls `appLeft`: the left pattern's
wholes are kept, but each event is cut into parts wherever the right pattern's events begin
and end inside it, every part joined with the right value it overlaps. Only the first part
starts where the whole starts, so only it is an onset and only it sounds — but every part is
still there to be queried, which is what lets a later `segment/2` or `struct/2` find a value
that began mid-event. `Control.set/3` given a pattern is `app_left/3`, so
`chord("<Bbm9 Fm9>/4") |> n("[0 ~ 2 ~](3,8)")` keeps the chord's four-cycle whole while
carrying each `n` in its own part, and the voicing and `segment(4)` after it play the melody
Strudel plays rather than four cycles of one chord. An event the right has nothing for is
left out, as `s("bd").gain("~")` is silent in Strudel. A continuous right pattern is read
once per event, at its start, as `add/2` reads it.

`segment/2` reads `value_at/2` at each step start, discrete or continuous, so it chops a
signal and also re-times a discrete pattern to a grid. `clip/2`, `fast/2`, `slow/2` and
`ply/2` given a pattern of amounts go through `patterned/3`: each amount is applied to the
whole pattern and queried over the amount's own span.

### Squeezing

`squeeze_values/2` replaces every event with a whole pattern of its own, fitted into the
event's span. It is what turns a chord name into the notes of the chord, sounding for exactly
as long as the name was written for. `squeeze/2` fits a copy of a pattern inside every event
of a structure, so where `fast/2` speeds a pattern up evenly, an uneven structure gives
unevenly sized copies.

Fitting uses `compress/3`, which measures from the start of a cycle, so an event in cycle 4
is asked for as the same slice of a cycle rather than as 4.25 to 4.5. An event straddling a
cycle line cannot be put that way and gives silence.

### Changing part of a cycle

`chunk/3` applies its function to the whole pattern and only then narrows the result to the
current chunk, so something like `rev/1`, which moves events out of the part it was handed,
still fills the chunk. `inside/3` changes the scale a function works at: `inside(p, 2, &rev/1)`
reverses each half of the cycle rather than the whole of it.

### Euclidean rhythms

`euclid/3` is Bjorklund's algorithm: `(3, 8)` is the tresillo, `(5, 8)` the cinquillo. Rests
are `silence/0`, so the result stacks over another pattern without gaps of its own. A negative
hit count inverts the result, so `euclid(p, -3, 8)` sounds on the five rests. `euclid_legato/3`
holds each hit until the next one rather than for one step: the difference between a
euclidean rhythm played staccato and played legato.

### Randomness

`rand/1` gives a new number at every instant, hashed from the position and a seed, so the same
position always gives the same value and a different seed gives a different sequence.
`degrade/3` and `sometimes_by/4` roll each event by the start of its `whole`, so the same
event in the same cycle is dropped or kept the same way every run, and
`stack([degrade_by(p, 0.4), undegrade_by(p, 0.4)])` is `p` again with nothing counted twice.

`perlin/1` wanders between one whole cycle and the next rather than jumping, so a filter swept
by it slides where one swept by `rand/1` rattles.

`degrade_by/3` is the Strudel spelling of `degrade/3`. `always/2` and `never/2` exist for
writing `always` or `never` where a chance was expected.

## TuningFork.Pattern.Control

Patterns of notes and the settings that shape them, written as a chain. Each function takes a
pattern and returns one, so they read left to right and stack in any order. The values are
maps of controls, which `TuningFork.Kit` turns into voices.

    import TuningFork.Pattern
    import TuningFork.Pattern.Control

    stack([
      s("bd*4") |> gain(0.9),
      s("hh*8") |> gain(0.4) |> pan(sine()),
      n("<0 4 0 9 7>*16")
      |> scale("g:minor")
      |> transpose(-12)
      |> shape(:saw)
      |> cutoff(300)
      |> resonance(9)
      |> lpenv(3.5)
      |> lpdecay(0.12)
    ])

### Starting a pattern

| | |
| --- | --- |
| `s/1` | a pattern of sounds: `s("bd*4")` |
| `n/1` | a pattern of scale degrees: `n("0 4 7")` |
| `note/1` | a pattern of notes by name or number: `note("c3 eb3 g3")` |

Each takes mini-notation, an already-built pattern, or a bare value.

### Shaping it

| | |
| --- | --- |
| `scale/2` | which scale the degrees are in: `"g:minor"` |
| `transpose/2` | semitones up or down |
| `octave/2` | which octave the scale sits in, 3 without one |
| `shape/2` | `:sine`, `:saw`, `:square`, `:triangle`, `:noise` |
| `gain/2` `pan/2` | how loud, and where |
| `release/2` | how long the tail is, in seconds |
| `acid/2` | the 303 squelch from one knob, 0.0 to 1.0 |
| `cutoff/2` | where the filter turns over, in hertz |
| `resonance/2` | how much it peaks there: 0.707 flat, 8 a howl |
| `lpenv/2` | octaves it sweeps above the cutoff over the note |
| `lpattack/2` `lpdecay/2` `lpsustain/2` `lprelease/2` | the shape of that sweep |
| `attack/2` `decay/2` `sustain/2` `adsr/5` | the shape of the note itself |
| `highpass/2` | a one-pole highpass, 0.0 to 1.0 |
| `velocity/2` | how hard it is struck; multiplies `gain/2` |
| `speed/2` | how fast it runs: 2.0 is an octave up and half as long |
| `bank/2` | which drum machine the names come from; see `TuningFork.Kit.banks/0` |
| `crush/2` `distort/2` | bits to round to, and how hard to drive it |
| `delay/2` `delaytime/2` `delayfeedback/2` | the note played again, later and quieter |
| `room/2` `roomsize/2` | the space it is all heard in |
| `jux/2` `jux_by/3` | this on the left, a changed copy on the right |
| `TuningFork.Pattern.add/2` | add to the controls rather than replacing them |
| `fm/2` `fmh/2` `fmattack/2` | a second oscillator bending this one |
| `vib/2` `vibmod/2` | how fast the pitch wavers, and how far |
| `coarse/2` `phaser/2` `phaserdepth/2` | hold samples, sweep a notch |
| `ftype/2` `bpf/2` `bpq/2` `hpq/2` | which kind of filter, and how it peaks |
| `vowel/2` | make it speak |
| `orbit/2` `postgain/2` `xfade/2` `compressor/2` | which bus, and what happens on it |
| `voicing/1` | a chord name to the notes that play it |

Every one of these takes a plain value or a pattern, so `gain(pattern, sine())` sweeps the
level across the cycle the same way `gain(pattern, 0.5)` pins it. The named functions are all
`set/3` with the key filled in; a pattern given as the value is sampled at each event's start,
and where it has nothing to say the event is left alone.

### The names Strudel uses

`lpf/2` is `cutoff/2`, `lpq/2` is `resonance/2`, `hpf/2` is `highpass/2` and `degrade_by/3`
is `degrade/3`, so an example copied from Strudel's workshop reads the same here. `size/2` is
`roomsize/2`, `struct/2`, `mask/2`, `early/2` and `late/2` are Strudel's, and `s/2`, `n/2`
and `note/2` set their control on an existing pattern so a chain can start with either.

### Strings are mini-notation everywhere

Every setter given a string reads it as mini-notation, as Strudel does: `room("<0 .2>")`
is 0 one cycle and 0.2 the next, and `bank("crate")` is a one-word pattern whose value is
`"crate"`. `struct/2`, `mask/2`, `late/2` and `early/2` take strings the same way, and
`mini/1` is the same reading with no control around it, for a string that has a method
called on it (`"<0 1>/16".early(.5)`). A string that will not parse raises as it does in
`s/1`, so a typo is reported rather than becoming a sound name.

A setter given a pattern is `Pattern.app_left/3`: the receiver's wholes, cut into parts
where the value pattern changes. `set/2` merges a whole pattern of controls the same way,
which is how `n("0 2") |> set(chords) |> voicing()` gives each degree the chord sounding
under it.

### Banks and General MIDI names

`bank/2` with a name from `TuningFork.Kit.banks/0` adjusts the synthesised kit; any other
name goes in front of each sound with an underscore, so `s("bd sd") |> bank("crate")` plays
`crate_bd` and `crate_sd` from `TuningFork.Sample.Bank`. A sound `gm_*` from
`TuningFork.Gm.Names` plays the General MIDI program it names on a `TuningFork.Gm` voice, at
the event's `:note`. An index after a colon picks a file from a bank name that holds several
(`sd:3`) and is ignored on a name that holds one.

### The filter controls

`resonance/2` at 0.707 is flat, 2 gives the filter a voice, 8 is a howl, and past about 12 it
rings on its own. `lpenv/2` is the movement an acid line is made of: a low cutoff, high
resonance, and a sweep of three or four octaves that falls away over `lpdecay/2`.

`acid/2` sets the whole filter from one knob, so a lead needs nothing else said about it.
Turning it up lowers nothing and raises everything else: more resonance, a deeper sweep, a
faster fall. At 0.0 it is a plain filtered saw. It sets `cutoff`, `resonance`, `lpenv`,
`lpsustain` and `lpdecay`, and anything chained after it wins, so `acid(0.5) |> lpdecay(0.3)`
keeps the squelch and lengthens the fall, and `acid(0.5) |> cutoff(600)` moves where it sweeps
from.

`ftype/2` chooses `:lowpass`, `:highpass` or `:bandpass`. `:highpass` and `:bandpass` are
always the clean state-variable filter, since the saturating ladder is a lowpass; see
`TuningFork.Filter`. `highpass/2` is a separate plain one-pole highpass with no resonance;
`hpq/2` applies only to the real filter chosen by `ftype(:highpass)` and `cutoff/2`.

### Buses

`room/2`, `postgain/2`, `xfade/2` and `compressor/2` belong to a bus rather than to a note.
`orbit/2` says which bus, counting from zero, and `TuningFork.Pattern.Player` keeps one
`TuningFork.Reverb` per bus and mixes each on its own before summing them, so the drums can
be dry on bus 0 while the lead swims on bus 1. `postgain/2` sets what a bus is worth in the
mix, so a whole layer can be brought down without touching how any of it was written;
`xfade/2` is the same said as a crossfade, equal at 0.5. A compressor pulls the loud moments
down so the quiet ones can come up: 0.5 is firm, 1.0 flattens.

### Delay and room are not the same kind of thing

`delay/2` is the note played again: real events, later and quieter, keeping the filter sweep
and pitch they had rather than being a copy of the mix. `echoes_of/1` gives the four repeats
of one event, with `delaytime` capped at half a cycle each, and `echoes/1` is the same as a
pattern, querying two cycles back so echoes of earlier notes land in the span asked for.
`TuningFork.Pattern.Player` uses `echoes_of/1`, not `echoes/1`: when a note with a delay
starts it puts the repeats on a pending list and starts each when its time comes, so the
pattern is queried once per block rather than over two extra cycles, and a repeat still
lands after the pattern it came from has been swapped out.

`room/2` is one space that everything on an orbit shares, run by `TuningFork.Reverb`, but
each note sends its own amount into it: the player mixes every voice dry, mixes the voices
scaled by their own `room` into a send, runs the send through the room and adds what comes
back, as superdough's orbit bus does. So a dry drum stays dry beside a wet chord, and the
tail rings on after the notes stop. `roomsize/2` (Strudel's `size`) is how many seconds
the room rings, 2 unless set; the last note to ask sets it for the orbit.

### Sound design controls

`fm/2` is frequency modulation. A whole-numbered `fmh/2` gives a harmonic tone (bells,
electric pianos, basses with a bite) and anything else gives a clangorous one. `fmattack/2`
holds the modulation back for a portion of the note, so the note starts clean and grows
teeth, which is most of what makes an FM bass sound plucked.

`vowel/2` is three bandpass filters at the frequencies a mouth resonates at. It works on
anything with harmonics to filter, so a saw speaks and a sine does not.

`crush/2` coarsens the level and `coarse/2` coarsens the time. `phaser/2` is four allpass
filters swept together, which move the notches they make about: the whooshing in a phaser
pedal.

`speed/2` doubles put the pitch up an octave and halve the length. Negative values are not
played backwards; they are taken as their size.

`bank/2` is carried through to `TuningFork.Kit`, which uses it to pick between kits of the
same drum names. A kit that does not know the bank plays its own sound rather than falling
silent.

### Drawing

`pianoroll/1` and `scope/1` mark a row to be drawn. Nothing is drawn for a row that does not
ask. Drawing costs a picture sent to the terminal every time it moves, so a session showing
one row moves smoothly where a session showing eight does not. A scope shows what reached the
speakers, which is everything playing rather than the row alone, so one is plenty.

### Chords

`chord/1` tags chord symbols, `dict/2`, `anchor/2`, `mode/2` and `offset/2` set how they
are voiced, and `voicing/1` turns each symbol into its notes through
`TuningFork.Pattern.Voicing`, one event per note with the symbol's whole and part — the
join Strudel calls `outerJoin`, so a chord written `<Bbm9 Fm9>/4` sounds for four cycles
and a chord cut by `n/2` keeps only the note `n` asks for. The voicing controls are dropped
from the notes; every other control on the chord event is kept. A symbol the dictionary does
not know is silent. `TuningFork.Pattern.arp/2` after it spreads the chord out instead.
`voicing/1` given a string is `chord/1` then `voicing/1`, for the older spelling.

## TuningFork.Pattern.Voicing

A port of Strudel's `renderVoicing` and its dictionaries (`ireal`, `ireal-ext`, `lefthand`,
`triads`, `guidetones`, `legacy`), generated from the Strudel source so a chord voices to the
same MIDI numbers here as there. A symbol is split into root and quality, the quality looked
up in the dictionary (with Strudel's aliases: `^` is major seventh, `-` minor, `+`
augmented), and each of the dictionary's voicings for it placed against the anchor: `:below`
keeps the top note at or under the anchor, `:above` the bottom note at or over it, `:root`
puts the root at the anchor, and `:duck` keeps the whole voicing under it. `offset` moves
along the list of voicings, and `n` picks one note of the chosen voicing, counted from the
bottom and wrapping by octaves. `render/2` answers `:error` for a symbol or quality it does
not have rather than guessing.

## TuningFork.Pattern.Mini

The mini-notation is that of TidalCycles and Strudel, read from a string.

| | | |
| --- | --- | --- |
| `bd sn hh` | in order, sharing the cycle | |
| `~` | a rest | `bd ~ sn ~` |
| `[ ]` | one step, subdivided | `bd [sn sn]` |
| `< >` | one per cycle, in turn | `bd <sn cp>` |
| `,` | at the same time | `[bd*4, hh*8]` |
| `*` | that many times a step | `bd*3` |
| `/` | over that many cycles | `bd/2` |
| `!` | repeated as separate steps | `bd!3` |
| `@` | that many steps' worth | `bd@3 sn` |
| `?` | dropped at random | `hh*8?` or `hh*8?0.3` |
| `( )` | euclidean, hits and steps | `bd(3,8)` or `bd(3,8,2)` |
| `:` | an index on a word, plain or patterned | `bd:3`, `sd:<2 3>` |

Modifiers stack left to right: `bd*2!3` is three steps of a doubled `bd`. `*` and `/` take
a bracketed or angled pattern as well as a number — `x*<1 2>` — read through
`TuningFork.Pattern.fast/2`'s patterned form. A number may be written without a leading
zero, so `[0 .01]*4` reads as Strudel writes it. A patterned index after a colon gives a
pattern of `word:index` strings, so `rd:<1!3 2>*2` is `rd:1` three cycles and `rd:2` the
fourth, twice a cycle.

Steps are counted at the top level, so `a [b c] d` is three steps however many things the
bracket holds. An item written `x@3` is three steps' worth, which is what its weight says.

A string that will not parse raises `ArgumentError` naming what was wrong and where, rather
than returning silence. `parse_safe/1` wraps that for a front end taking what somebody is still
typing.

`located/1` keeps every value paired with the character span it was written at, and
`locate/2` reads that back for one absolute cycle position, so a front end can highlight the
token that is sounding. Timing applied outside the string (`fast/2` on the parsed pattern) is
not seen, so a highlight follows the notation rather than the chain around it.

## TuningFork.Pattern.Player

The player owns no clock, in the same way as `TuningFork.Transport`: the frames it is asked
for are the clock, so its position is exactly the audio that has been produced. A pattern has
no end, so the player loops forever and `cycle/1` reports where it has reached.

### Swapping while it plays

`update/3` puts a new pattern in without stopping. `at: :cycle` holds the new pattern until the
next cycle line, which is what makes an edit land in time rather than halfway through a bar.
`at: :now` takes effect on the next block. Either way the position carries on, so a pattern
that counts cycles keeps counting. Notes already sounding finish as the pattern read when they
started.

### Voice cap

Past the `:voices` cap the oldest notes are faded out over 10 ms rather than cut, which would
click. A fading note is still counted by `sounding/1` for the few milliseconds it takes to go
quiet; `playing/1` counts only the ones that are not on their way out.

### Recordings still on their way

A voice for a recording that has not been fetched from the web yet would block the mix for
as long as the download takes, so the player's voice function on a stage is
`TuningFork.Kit.voice/3` with `wait: false`: the fetch starts in the background, that hit is
silent, and the next one plays. `TuningFork.Sample.Set.load/1` also starts fetching every
file of a set as soon as the set is named, so by the time a pattern reaches a sound it is
usually there. Offline rendering keeps waiting, since a file is worth a pause there.

### Buses

Each voice carries its route, `{orbit, room}`. Each orbit is mixed on its own — every voice
dry, plus the room fed by each voice at its own `room` amount — levelled on its own, and only
then summed. That is what makes a bus a bus: the drums can be dry while the lead swims.

A bus setting (`room`, `roomsize`, `postgain`, `xfade`, `compressor`) belongs to the bus
rather than to one note, so the loudest ask in a block wins and holds until something says
otherwise, which lets a reverb tail keep ringing after the note that asked for it.

The compressor pulls the peak of each block back towards a target level, which levels one bus
against another without needing a detector that runs ahead of the audio.

### Rendering without a device

`render/3` renders a stated number of cycles to signed 16-bit PCM, ready for
`TuningFork.Wav.encode/2`, which is how a pattern is heard somewhere with no speaker of its
own, a notebook in a browser being the usual case. The result closes without a break: a tail
of silence is rendered past the last cycle and folded back over the beginning, so a note held
across the cycle line is heard at the start of the next time round.

## TuningFork.Pattern.Source

A typed line is one of two kinds. A line beginning with a function name from
`TuningFork.Pattern` or `TuningFork.Pattern.Control` followed by `(` is evaluated as Elixir
with both modules imported; anything else is read as mini-notation. `starts_code?/1` is the
test, so a front end can show which of the two a line is before running it.

The openings are taken from the two modules' exported functions rather than listed by hand,
so the list cannot go stale when either module grows. A stale list shows up as a perfectly
good line being read as mini-notation and reported as a syntax error in it.

Either kind reports rather than raising: `{:error, message}` with the reason as the parser or
the compiler gave it, trimmed to one line.

A line of Elixir is evaluated, so it can do whatever Elixir can. That is the same bargain
TidalCycles and Strudel make, where the person typing is the person running it, but it means
a line from somewhere else should be read before it is played.

A line beginning `|>` carries on the one above it. A front end writing a chain down the screen
joins such lines to the one they follow before parsing; on its own a continuation is not a
pattern.

## TuningFork.Part

A part is written by moving through it rather than by counting into it. It carries a cursor
measured in beats: `play/4` puts a note where the cursor is and moves it on by the note's
step, and `rest/2` moves it without playing anything.

How long a note lasts and how long until the next one are two separate things. The step is
how long until the next note; `:release` is how long this note goes on sounding, and may be
longer than the step, in which case notes overlap.

Each part is written from its own beat zero and they are mixed by `TuningFork.Score`, so a
part that comes in later says so itself with a leading `rest/2`.

Every part has its own seeded random generator, so anything random in it renders the same
every time. `{:between, low, high}` option values, `play_any/4`, `maybe/4`, `pick/3` and
`between/3` all draw from it.

`steps/4` places every step the same distance apart; `pattern/4` is for when the spacing
itself varies.

## TuningFork.Score

A score is a length in beats, a tempo map, notes placed on beats, and layers: groups of notes
with their own effects. `render/3` produces exactly `:beats` beats of audio. A note whose tail
runs past the end is wrapped back to the start, so the loop point is inaudible. Each layer is
rendered on its own so its effects reach nothing else, and whatever those effects add past the
end is folded back over the start.

Notes are synthesised in mono and panned as they are placed, so two notes differing only in
gain or pan share one render.

A score runs at one tempo at a time. Parts at genuinely different rates at the same moment
are not supported: `from_parts/2` refuses parts written at different tempos rather than
playing them at the first one's, which would put every other part's notes at the wrong
moment. Give each part the same `:bpm`, or build a score for each.

`repeat/4` refuses a step of zero or less, which would never reach the end of the score.

## TuningFork.Session

A live-coding session is a list of rows. Some are switched off, some carry on the row above
them, and together they make one pattern. That much is the same whether the rows are lines in
a terminal, cells in a notebook or fields on a page, so it lives here rather than in any of
them.

A row is any map with a `:source`. `checked/1` also writes an `:error`. Anything else on the
map is left alone, so a front end can keep its own things there: a cursor, a colour, a widget
id.

A row is off when it is empty or begins with one of `--`, `//` or `_`. An off row is not
played, not drawn and not checked, so a half-written line parked behind a `_` never reports
anything. The markers are checked longest first so the longest match wins.

A row beginning `|>` carries on the one above it, so a chain too long for one line is written
the way it reads:

    1  n("<0 4 0 9 7>*16")
    2  |> scale("g:minor")
    3  |> acid(0.55)

Those are one row as far as playing and error reporting go. `joined/1` reports
`{first, last, source}`: `first` is the line to hang an error on, `last` the line to draw a
picture under. Off rows are left out with their line numbers, so the indexes reported are
always into the list as given. A continuation with nothing above it is dropped rather than
run on its own.

`combined/1` leaves out a row that will not parse rather than failing the lot, so one bad line
does not silence the rest and a session keeps playing while something is half typed.

Rows that read as Strudel — `TuningFork.Strudel.strudel?/1` on all of them joined, which
looks for method chains and `$:` labels and no `|>` — are given whole to
`TuningFork.Strudel.chains/1` instead of being folded row by row, so a piece pasted from
strudel.cc plays without being rewritten. The chains it gives carry the line span of the
statement they came from, so an error still hangs on the line and a picture still draws
under the last one. A piece that will not translate becomes one chain on the line of the
fault whose source is the whole text; `fault/1` recognises that as Strudel and reports the
translator's message rather than the Elixir parser's. `tempo/1` reads `setcps` from a
Strudel piece and `nil` from anything else, so a front end can take the tempo the piece
asks for and otherwise keep its own.

`asks?/1` reads what a row wants drawn from the parsed pattern rather than by looking for the
word in the text, so a row mentioning `scope` in a sound name is not mistaken for one asking
for it. Nothing is drawn for a row that does not ask, which keeps a session with eight rows
from sending eight pictures a frame.

## TuningFork.Session.View

Everything here answers a question about a row that a terminal, a notebook and a web page all
ask in the same words: where is the playhead, which token is sounding, what does this row's
waveform look like, where do its notes sit. None of it knows what a pixel is. Turning any of
it into blocks, an image or an SVG belongs to the front end.

A row that is off or will not parse gives nothing back rather than raising, so a half-typed
line draws blank instead of stopping the drawing.

The scope is rendered from the row's own pattern rather than read off the speakers, so it
shows the row it is written under and not everything playing. Its window starts at the row's
last note, not at the playhead, and is scaled by `fade/2`, so it snaps to full height as a
note lands and dies away until the next one. The beat is visible without the picture having
to scroll, and a row between notes settles on one picture instead of being redrawn.

`fade/2` never falls quite to nothing, so a quiet row stays faintly visible rather than
blinking out. It is quantised to a fixed number of steps, so a trace that is not changing is
identical rather than merely close, which lets a front end skip redrawing it. `struck/2` gives
the playhead itself when nothing has started yet, so an empty row is measured from the
playhead rather than from nowhere.

The notation a code row plays is inside its first quoted string, so `sounding/2` measures the
highlight there and then moves it out to where that string sits in the line.

`widths/2` is how wide a pianoroll draws each note, as a bar rather than a dot.

## TuningFork.Sink

A sink is opened once, written to in chunks, and closed. `TuningFork.Sink.Silent`,
`TuningFork.Sink.Collect` and `TuningFork.Sink.Buffer` ship with the library;
`TuningFork.Sink.Speaker` comes from the separate `tuning_fork_speaker` package. Any module
implementing the behaviour is a sink.

`write/2` must not block the caller for longer than the audio it is given represents, or
playback falls behind. `TuningFork.Stage` passes `:rate` and `:channels` to `open/1`, so a sink
is always told what shape the samples it is handed are.

A `write/2` that returns `{:error, reason}` ends playback: the stage logs the reason and stops
feeding that sink, rather than looping on a destination that is no longer taking samples. A
sink reports a failure rather than returning `:ok`, or a device that has gone away is
indistinguishable from one playing correctly.

`TuningFork.Sink.Silent` is the default sink and the one a stage falls back to when its
configured sink will not open. `TuningFork.Sink.Collect`'s `write/2` sleeps for as long as
the audio it is given lasts, so it paces a stage the way a real device does.

## TuningFork.Sink.Buffer

The buffer records a stage rather than playing it. Writing does not sleep: chunks are taken as
fast as the mixer makes them, so a piece records in as long as it takes to render rather than
in as long as it lasts.

The buffer is a process the caller starts and owns; the sink writes into it but does not own
it, so the recording outlives the stage that filled it. The rate and channel count the stage
opened with are remembered in the buffer for `wav/1` and `duration/1`.

## TuningFork.Source

`TuningFork.Pattern.Source` and `TuningFork.Part.Source` read different languages, a row of
pattern notation and a block of loop code, and report problems the same way through this
module. `run/1` evaluates without letting diagnostics reach standard error, since
`Code.eval_string/3` writes to standard error before it raises, which a `rescue` cannot take
back. `one_line/1` turns an exception message into the one sentence worth putting under the
line it belongs to.

## TuningFork.Stage

### Mixing and writing

`play/2` is a cast and returns immediately; the voice is rendered inside the stage and mixed a
chunk at a time until it runs out. A separate linked process does the writing and pulls each
chunk from the stage when the sink is ready for one, so the sink's pace is what drives the
mixer. Stopping a stage stops its writer with it, and does not disturb the process that called
`start_link/1`.

A stage whose sink will not open logs and falls back to `TuningFork.Sink.Silent` rather than
failing to start. A silent stage still keeps time: its writer pulls a chunk every `:chunk`
frames' worth of wall clock and throws it away, so `beat/1` advances and a score plays through
to its end on a machine with no audio device.

The default `:chunk` of 512 frames is about 12 ms at 44100. The default `:scope` window of
4096 frames is about 93 ms at 44100; one chunk is too short for a scope to settle on.

`:limit` is where peaks start being rounded off rather than flattened. `nil` turns it off and
lets a loud mix clip square.

### Held notes

`hold/3` sounds a voice under a key and `release/3` lets it go: the voice is started with its
envelope's hold stretched to an hour, kept in the sounding list tagged with the key, and on
release replaced by the same voice fading from the level it has reached, as
`TuningFork.Voice.Live.release/2` does for the voice cap. A voice whose envelope decays to
nothing ends on its own under the key. Holding a key already held releases the first, so a
keyboard's repeated note does not stack. This is what `TuningFork.Midi.In` plays a keyboard
through.

### Three ways to put music through it

* `start_pattern/3` plays a `TuningFork.Pattern`, swapped at the cycle line.
* `start_loop/4` plays named loops, each on its own length.
* `start_score/3` plays one piece, through once or looped.

They mix, so a pattern can run under a set of loops. A stage plays one pattern and one score
at a time. `update_pattern/3` changes the pattern without going back to cycle zero, which
starting it again would do.

### The bed

The bed is read by sample position and wraps, so it never drifts against the events mixed over
it and the loop point is where the buffer ends. A bed shorter than one chunk is wrapped as
many times as it takes to fill the chunk. Bed gain is applied as the bed is mixed, so it takes
effect on the next chunk without the bed being rendered again.

### Scores

The transport started by `start_score/3` is advanced by the same chunk pull that drives the
sink, so its position is exactly the audio that has been written.

A finished piece loops better through `TuningFork.Score.render/3` into `bed/2`, which closes
the loop cleanly and folds effect tails back to the beginning; a transport does neither.

### Loops

Where `start_score/3` plays one piece, `start_loop/4` plays as many as you like at once, each
with its own length and its own place in it, which is what lets a four-bar bass run under a
three-bar melody without either being stretched to fit. A loop is a `TuningFork.Score`, which
is what `TuningFork.Part` writes.

`update_loop/4` swaps a loop's score and by default holds it until the loop comes round, so an
edit lands on the downbeat rather than halfway through the bar. Starting a loop under a name
already running replaces it from the next chunk instead.

A loop given a `:body` is worked out again for every round. `TuningFork.Tick` counters step,
`TuningFork.State` values are read as they stand, and a loop can play something different
every time round rather than the same score for ever:

    {:ok, body} = TuningFork.Part.Source.compile(source)
    {:ok, first} = body.()

    Stage.start_loop(stage, :bass, first, body: body)

The body for a round is worked out during the round before it, in a process of its own, so the
audio is never waiting on it. A body that raises, or that has not finished in time, leaves the
loop playing what it played last; the sound carries on either way. A round's score is only
accepted if the loop is still on the round it was worked out for.

`after_round/3` is how one loop waits for another: a loop that wants to come in on another
one's downbeat waits there. Everyone waiting on a loop that has just come round is let go at
once, which is what makes several loops able to start together on one downbeat. A name that is
not running is refused at once rather than waited on forever, so a mistyped name is noticed.

### Patterns

`pattern_cpm/2` is the same knob as `pattern_cps/2` in cycles per minute, where 120 is two
cycles a second. `hush/1` silences what the pattern has already triggered while its transport
carries on, so the next events land in time. The reverb rooms for a pattern live in the
player, one per orbit, because that is where the notes know which bus they went to.

### Meter and scope

`level/1` is the peak of what actually went to the sink, after effects and limiting, so it is
what a meter should show.

`scope/2` is what an oscilloscope draws, taken after effects and limiting from the left channel
only, so the shape is the one that reached the sink. The window is the last `:scope` frames,
not the last chunk. A chunk is a few milliseconds, less than one cycle of a bass note, so a
scope drawn from one chunk shows a different fragment every frame and never settles. The
window is also aligned to a rising zero crossing, which is what holds a repeating waveform
still on screen instead of letting it slide.

## TuningFork.State

`set/2` writes at the time of the round doing the writing. `get/2` reads the newest value
written at or before the time of the round doing the reading, so a loop that has run further
ahead than another cannot hand it a value from the future. Two loops on the same round get the
same answer whichever order they were worked out in, and a piece plays the same twice.

A `TuningFork.Stage` runs a loop's body for the round it is about to play and tells the store
which frame that round begins on. Outside a loop the time is `0`, so `set/2` then `get/2` in
IEx behaves as anybody would expect.

`get/2` never blocks; it answers with what it has. To hold a loop until another has been
round, use `TuningFork.Stage.after_round/3`.

## TuningFork.Store

Two ETS tables owned by one process, started with the application. Reads and writes go
straight to ETS rather than through the owner, so a loop body reading state never waits on a
process.

A value is stored with the logical time it was set at, as a frame count on a stage's clock.
The table is an `:ordered_set` keyed by `{key, time}`, so reading the value as of time `t` is
a walk backwards from `{key, t + 1}`: one `:ets.prev/2`, whatever the history's size.

A loop body is run for the round it is about to play, not the one playing now, so the time it
reads and writes is that round's own start. `as/3` sets it; `at/0` reads it back. Outside a
loop the time is `0`.

Everything a tick or a value does is a function of the store, so a piece plays the same from a
fresh one. `clear/0` empties both tables.

## TuningFork.Voice

A voice is a waveform at a pitch, shaped by an envelope, optionally swept in pitch and
filtered. It is always synthesised in mono, whatever the output is: `render/2` gives that mono
buffer, which is the same for a note wherever it ends up sitting, and `render/3` places it for
a given channel count.

### Filters

`:filter` is a `TuningFork.Filter`, a resonant lowpass cut off at a frequency in hertz and
optionally swept by its own envelope. It is the one that shapes a tone. `:cutoff` is a one-pole
lowpass of 6 dB an octave with no resonance, which barely dents a sawtooth: a smoother rather
than a filter. Use `:filter` to shape a sound and `:cutoff` to take the edge off one.
`:highpass` set together with `:cutoff` gives a band.

### Modulation

`:curves` holds `TuningFork.Curve`s, each a multiplier over the field it names, read across the
note from start to end:

    Voice.new(freq: 440.0, curves: %{freq: Curve.linear(1.0, 1.5)})

`:sweep` is the same thing stated shortly. A `:freq` curve supersedes it where both are given,
including a flat one. `modulation/1` resolves the curves actually moving on a voice;
`TuningFork.Voice.Live` uses it so that a voice rendered a block at a time reads the same
curves as one rendered whole.

Frequency modulation and vibrato both bend the carrier's phase rather than its frequency, which
is the same thing said in a way that needs no state beyond the modulator's own phase. `:fm`
is superdough's index: the modulator, at `:fmh` times the carrier, swings the carrier's
frequency by `fm × fmh × freq` hertz, which bends its phase by `fm` radians — `fm / 2π` of a
cycle — so `fm(4)` is the same sound here as there. The bent phase is wrapped before the
waveform reads it, so a square or triangle never sees a phase outside its cycle.

### Saturation

A resonant filter has enormous gain at its cutoff, roughly the square of `:q` for four poles,
so a voice with any real resonance on it goes over full scale. Cut off there it becomes a
square wave, which is the harsh digital sound a filter sweep is not supposed to make. An analog
filter saturates instead, and that saturation is most of why a resonant sweep sounds the way
it does. `saturate/1` bends a sample towards full scale rather than letting it run past and be
cut off; below 0.7 nothing is changed, so an ordinary voice is untouched.

### Waveshaping

`:waveshape` is Strudel's `shape`: `(1 + k) x / (1 + k |x|)` with `k = 2s / (1 - s)`, from
its shape worklet, so `shape(.3)` in a Strudel piece bends the same way here. It sits after
`:distort` and before `:crush`. `Pattern.Control.shape/2` sends a number there and an atom
to the waveform, since Strudel's `shape` and this library's `shape` had the same name for
different things.

### Vowels

A vowel is not a pitch but a pattern of resonances: the mouth has peaks at three frequencies,
and which three decides which vowel is heard however high or low the voice. Passing a sound
through bandpass filters at those frequencies makes it speak. `TuningFork.Filter` normalises a
resonant bandpass by its own q, which is right for a filter asked for on its own and wrong for
a formant, where the peak is the point, so the formant sum is multiplied back up.

### Phaser

The phaser is four one-pole allpasses in series, their corner swept by an LFO. An allpass
leaves the loudness alone and only moves the phase, so it is inaudible until it is added back
to the dry signal; where the two disagree they cancel, and the notches that makes travel with
the sweep. That travelling is the whole sound.

### Crush, coarse and distort

`crush/2` coarsens the level: 4 bits is unmistakable and 1 is a square wave. Fractional values
work, since the step size is what matters rather than the bit count being whole. `coarsened/3`
coarsens the time instead, holding each sample for several; the aliasing that comes of it is
the point. `distort/2` drives through a soft clipper and takes the level back afterwards, so
turning it up dirties the sound rather than simply making it louder.

## TuningFork.Voice.Live

`TuningFork.Voice.render/2` synthesises a whole note at once. A live voice is the same
arithmetic stopped at the end of a block instead. `advance/2` hands back that block and a voice
that remembers where it got to, so the next block carries on from the same phase, filter state
and noise seed, and the voice can be changed in between.

The note's length is fixed at `start/2` from the voice's envelope, and curves are read across
that length. Changing the envelope with `control/2` afterwards does not change the length;
`release/2` does. `control/2` resolves curves again, so new ones take effect and are still
measured across the note's whole length, while phase, filter state and noise seed are
untouched. The pan is read per block, so a voice whose `:pan` is changed while it sounds moves.

`release/2` replaces the envelope by a release from whatever level the voice had reached, and
restarts the voice at frame zero with a length of the release time. Every curve is frozen at
the value it had reached and `:sweep` is set to 1.0, so pitch and filter stay where they were
heard while the level falls.

A live voice cannot be cached, since it is a different thing on every play.
`TuningFork.Transport` plays a voice with no modulation from a rendered buffer instead, and
uses a live voice only where something is moving.

## TuningFork.Wav

Sixteen-bit little-endian out, in either mono or stereo. `encode/2` writes a WAV that
`Kino.Audio`, an `<audio>` element or a Phoenix response can take directly:

    score
    |> TuningFork.Score.render(44_100)
    |> TuningFork.Wav.encode(rate: 44_100)
    |> then(&Kino.Audio.new(&1, :wav))

The rate and channel count must be given to `encode/2` because nothing in a PCM buffer records
them.

`decode/1` reads audio TuningFork did not produce, for playing through
`TuningFork.Stage.play_pcm/2` or loading as a `TuningFork.Sample`. Chunks other than `fmt `
and `data` are skipped, so a file carrying a `LIST` of who made it reads fine. A file that ends
inside a chunk is `:truncated` when the missing part might be `fmt ` or `data` itself. Once
both of those have been read the audio is whole, so a stray chunk cut short after them is
ignored rather than losing a file that plays.

What comes back is always 16-bit: 8-bit unsigned, 24- and 32-bit integer and 32-bit float
samples are converted on the way in, floats clipped to -1.0..1.0, and an extensible header
(`0xFFFE`) is read for which of those its sub-format names. Sample packs published for
Strudel are mostly 24-bit, so this is what lets `samples('github:…')` play. A depth other
than those is refused by name.

## TuningFork.Wave

Noise ignores phase and takes a seed instead, returning the next value with it. It is a linear
congruential generator, so the same seed gives the same sequence on any node and in any
process.

`sample/3` is what a voice uses; `sample/2` is the raw shape, and `:saw` and `:square` alias
at high frequencies without the correction `sample/3` applies. `:saw` and `:square` jump
instantaneously once a cycle, and sampling that jump directly folds every harmonic above
Nyquist back down as noise that is not related to the note. `sample/3` rounds the jump over
the sample either side of it, which removes most of that folded-back energy. `:sine` has no
jump to round, and `:triangle` bends rather than jumps, so both ignore the step.

## Mix.Tasks.TuningFork.Render

The file is read with `TuningFork.Midi`, given instruments by `TuningFork.Gm` and rendered by
`TuningFork.Score`, which closes a loop cleanly and folds an effect's tail back over the join.
No audio device is opened. `--gain` is worth lowering for dense music; `--no-guess` treats only
channel 10 as percussion, as General MIDI specifies, where otherwise the drum channels are
guessed.

## TuningFork.Kit

Levels follow superdough's: a recording plays at 1.0, a synthesised note and a soundfont note
at 0.3, so a Strudel piece balances here as it does there. A sound named after a waveform —
`sine`, `sawtooth`/`saw`, `square`, `triangle`/`tri`, `white`/`pink`/`brown` — is that raw
oscillator with no filter, as Strudel's synths are; `TuningFork.Strudel` puts `s("triangle")`
on any row that names no sound, since that is Strudel's default. A note with no sound in
this library's own rows keeps the filtered saw.

`voice/2` answers to drum names (`bd` `sn` `hh` `oh` `cp` `rim` `lt` `mt` `ht` `rd` `cr` and
their aliases), a drum name with an index (`bd:2` — the index detunes it), a note name (`c4`
`fs3` `eb5`), a whole number as a MIDI note, a float as hertz, a `TuningFork.Voice` as
itself, a `TuningFork.Sample.Bank` name as a voice carrying the recording, and a map. Anything
else is `nil`, which a player takes as silence. A synthesised drum wins over a bank sample of
the same name.

A map carries a sound and what to change about it: `:sound`, `:note` or `:degree` say what to
play; `:gain`, `:pan`, `:shape`, `:release`, `:cutoff` (hertz), `:resonance` (0 flat, 9
squelches, 62 as far as it goes), `:lpenv`, `:lpattack`, `:lpdecay`, `:lpsustain`, `:highpass`
and the rest of `TuningFork.Voice`'s fields say how. `:cutoff` is hertz because the filter is
`TuningFork.Filter`, a saturating four-pole ladder; a `:lpenv` of 3 with a short `:lpdecay` is
the acid sound. Only a lowpass can be the ladder; a highpass or bandpass is the clean filter.

The amp envelope's `:hold` is left as the voice set it, so shortening a note's attack does not
change how long it sounds. Frequency modulation puts its sidebands well above the note, and the
filter a pitched voice comes with sits just above it, so a voice asked for FM and not for a
cutoff has its filter opened up to 12 kHz.

Banks are sets of adjustments to the synthesised drums — how much longer they ring, how much
the low ones are detuned, how bright the rest are — under the names Strudel uses
(`RolandTR808`, `RolandTR909` and so on). A name the kit does not know changes nothing.

## TuningFork.Flac

A pure-Elixir FLAC decoder. Every subframe type (constant, verbatim, fixed and LPC of any
order), both Rice partition widths, wasted bits, fixed and variable block sizes, and all four
stereo layouts (independent, left/side, right/side, mid/side) are read. Output is always
signed 16-bit little-endian interleaved PCM: 8-bit is scaled up, 24-bit down. CRCs are not
checked, so a corrupted stream comes back as noise rather than an error; a truncated stream is
`{:error, :truncated}`, and more than two channels is `{:error, :unsupported}`.

Rice decoding reads unary runs a byte at a time through a leading-zero table, and prediction
walks a reversed sample list so the last `order` samples are always at its head. A 30-second
24-bit stereo file decodes in under half a second; a drum hit in a millisecond.

## TuningFork.Sample

A sample is mono 16-bit PCM with the rate it was recorded at. On a voice it becomes an
ordinary voice: envelope, filters, pan, modulation curves and every effect apply as they do
to an oscillator, and it sits in a part alongside synthesised notes.

Pitch is speed: the recording is resampled, so a note an octave up is half as long. `:root`
says what pitch the recording is, and a voice asking for another is read faster or slower by
the ratio; without a root the recording plays at its own speed whatever pitch is asked for.
There is no time-stretching. Reading between frames is a four-point cubic Hermite curve,
which keeps the top octave of a cymbal that linear interpolation dulls; sustained material
pitched far up still aliases.

A voice sounds for as long as its envelope, never for as long as its recording. A voice given
a sample and no envelope gets one cut to fit; a shorter envelope gates the recording, a
longer one leaves room for a varispeed sweep to finish.

`load!/2` reads WAV or FLAC, told apart by the file's header rather than its name.

## TuningFork.Sample.Bank

One public ETS table owned by `tuning_fork`'s supervisor, mapping names to a list of files
with load options and the samples loaded from them so far, keyed by index. A file is read on
the first `fetch/2` of its index and the sample kept, so a bank of hundreds of files costs
nothing until a name is played. A name may hold several files — Strudel's `sd:3` picks the
fourth — and an index past the end wraps, so `bell:3` on a single recording is `bell`. A
file may be an `http(s)://` URL, fetched through `TuningFork.Sample.Fetch` when first
played. Names are strings or atoms and are the same either way. A path that will not load
answers `:error` and is not retried as a success. `tuning_fork_samples` fills the bank with
Sonic Pi's recordings when its application starts.

A name registered from a map of note names to files is a pitched instrument, Strudel's
`piano.json` shape: the files are kept in note order with the MIDI note each was recorded
at, and `nearest/3` picks the file recorded closest to the note asked for, `n` choosing among
files that share a note. `TuningFork.Kit` plays it with that file's note as the root, so the
nearest recording is repitched the least. A plain recording given a note is repitched from
C2 (MIDI 36), which is where Strudel puts an unpitched sample.

`n` on a recording or a kit drum picks which file, as Strudel's `n` does for samples —
`n("0 1").s("hh")` is `hh:0 hh:1` — unless a `scale` or a `note` is on the event, in which
case it is a degree as it is for a synth.

The bank comes before the synthesised drum kit: a `bd` registered from a sample set is what
`s("bd")` plays, and the kit's own `bd` only sounds while no recording of that name is
registered. `prefetch/1` starts fetching every file of a name in the background; the
`TuningFork.Pattern.Player` calls it, through `TuningFork.Kit.prefetch/1`, for every sound
in the first eight cycles of a pattern it is given, and for the soundfonts behind `gm_*`
names, so that by the time a note is due its recording is on disk.

## TuningFork.Sample.Fetch

Downloads a URL once into `$XDG_CACHE_HOME/tuning_fork/samples` (or
`~/.cache/tuning_fork/samples`), named by a hash of the URL with the URL's extension kept,
and answers the local path; a second fetch of the same URL is a file check. It uses
`:httpc` from `:inets`, following redirects, so there is no HTTP dependency to add.

Downloads run as tasks under `TuningFork.Sample.Fetch.Supervisor`, each registered by URL in
`TuningFork.Sample.Fetch.Registry`, so a URL is never fetched twice at once: `fetch/1` joins
a download already under way and waits for it, and `prefetch/1` walks a list in the
background one file at a time (a list already being walked is skipped), returning at once.
A download that fails leaves nothing in the cache, so the next `fetch/1` tries again and
reports the error.

## TuningFork.Sample.Set

A `strudel.json` is a map of names to a file or a list of files, with an optional `_base`
every file is relative to. `load/1` reads one from a `github:user/repo[/branch]` reference
(the raw file on that branch), any URL, a local path, or a map already decoded, and
registers every name in the bank with its file URLs, so the files themselves are only
fetched as they are played. It is what Strudel's `samples('github:eddyflux/crate')` becomes.
The JSON itself goes through `TuningFork.Sample.Fetch`, so it is downloaded once, and
registering a name again with the same files keeps its loaded samples; both matter because
a front end translates a Strudel buffer — and so reaches `samples(...)` — every time it
checks or draws it.

## TuningFork.Sample.Font

Strudel's `gm_*` instruments are soundfonts served as webaudiofont files: one JavaScript
file per instrument holding a list of zones, each a key range, a root pitch in cents, loop
points and an MP3 in base64. `parse/1` reads the zones out of the file with a small
regular-expression scanner rather than a JavaScript parser, since the files are all of one
shape. `load/1` fetches the file through `TuningFork.Sample.Fetch`, writes each zone's MP3
into the cache and decodes it through `TuningFork.Sample.Decode`, keeping the result in an
ETS table as a `TuningFork.Sample` with `root` from the zone's pitch and tuning and `loop`
from its loop points, scaled if the decoder's rate differs. A note picks the zone whose key
range covers it, as Strudel's `findZone` does. `sample/3` with `wait: false` starts the load
in the background and answers `:loading`, so a stage never waits on a font; `prefetch/1`
does the same without asking for a note. Fonts that will not decode load with the zones
that did, and a note no zone covers is `:error`, which `TuningFork.Kit` turns into a
synthesised voice.

`TuningFork.Gm.Fonts` is the list of font files behind each name, in Strudel's order, so
`gm_epiano1:1` is the second file as it is there. The voice a font plays through has
Strudel's soundfont envelope — an instant attack, sustain for the note, a 10 ms release —
at 0.3 of a recording's gain, which is the level Strudel gives them.

## TuningFork.Sample.Decode

MP3, OGG and AAC are not decoded here; `to_wav/1` hands them to `afconvert` on macOS or
`ffmpeg` where it is installed, writing a 16-bit WAV into the cache directory once, named
by a hash of the source path. A WAV or FLAC is returned as it is. With neither converter
the answer is `{:error, :no_decoder}`, and `TuningFork.Sample.load!/2` raises with it, so a
font or a piano note on such a machine is skipped rather than played as noise.

## TuningFork.Gm.Names

Strudel's `gm_*` instrument names and the General MIDI program each stands for, generated
from Strudel's soundfont list, so `s("gm_epiano1")` plays program 4 on a `TuningFork.Gm`
voice. A name with an index, `gm_epiano1:1`, is the same program; the index chooses a
soundfont in Strudel and has nothing to choose here.

## TuningFork.Fx

Each whole-buffer effect gives back PCM longer than it started, because an echo or a reverb
goes on after the last note; `TuningFork.Score` wraps that tail back to the start of a loop.
`:mix` is how much of the result is the effect. Every effect takes `:channels`, default 2,
because a delay is measured in frames while the buffer is walked a sample at a time; both
channels are delayed by the same whole number of frames, so nothing here widens a stereo
image. Effects `TuningFork.Fx.Live` has and this module does not — filters, slicers, the
compressor and the rest — are run through a fresh streaming chain over the whole buffer.

## TuningFork.Fx.Live

The same echo, reverb and drive as `TuningFork.Fx`, held as state so a block can be handed in
at a time and the tail carries into whatever is played next; the arithmetic and delay lengths
match, so a piece sounds the same either way. `TuningFork.Stage` puts one over everything it
mixes and `TuningFork.Transport` runs one per effected layer.

The streaming-only effects: `:level`; `:lowpass`, `:highpass` and `:bandpass` as a
topology-preserving state-variable filter with one state per channel (a `:q` of 0.7 is flat);
`:slicer` and `:tremolo` as an amplitude driven by a low-frequency oscillator; `:wobble` as a
lowpass whose cutoff sweeps between two frequencies on the same oscillator; `:crush` as bit
reduction plus sample-and-hold, with `:sample_rate` turned into a hold count from the render
rate; `:compressor` as an envelope follower with attack and release coefficients and a gain
computed from where the envelope sits against the threshold; `:pan` and `:panslicer` as
equal-power channel gains, static or swept, which leave a mono stream alone; `:flanger` as a
short delay line read at a position that the oscillator moves, with linear interpolation, kept
as a map so a write per sample stays cheap.

The oscillator is one of `:saw` (falling), `:square` (on for `:pulse_width` of the phase),
`:triangle` and `:sine` (a cosine, so it starts at its peak), and every effect that has one
counts frames so its position carries across blocks.

## TuningFork.Transport

A transport owns no clock: the frames it is asked for are the clock, so its position is
exactly the audio produced. A note lands on its own sample inside a block rather than at the
block boundary. The score can be swapped while it plays and the position is kept. What it
cannot do, and `TuningFork.Score.render/3` can, is close a loop without a seam, fold a tail
back to the start, or cache a repeated note. With `:loop` the position goes back to the start
at the end; notes already sounding finish rather than being cut.

A score's per-layer effects are applied live: every sounding voice carries its layer's effect
list, blocks are grouped by that list, each distinct list has a `TuningFork.Fx.Live` chain of
its own, and the chain keeps being fed silence after the layer's last note so an echo or a
reverb rings out. A chain silent for eight seconds is dropped.

## TuningFork.Part.Source

What `TuningFork.Pattern.Source` is for a row of pattern notation, this is for a block of
loop code: the one place that turns what somebody typed into something a stage will play, and
says what is wrong when it will not. The source runs under `use TuningFork.SonicPi`, so a loop
reads either as a `TuningFork.Part` pipeline or in Sonic Pi's words; a bare part is wrapped in
a score of its own length, a score is taken as it is, and source that plays with `play`,
`sample` and `sleep` gives the round those made. Errors come back as one line and nothing is
written to standard error, so a terminal front end is not scrolled over by a half-typed loop.
The source is Elixir and can do whatever Elixir can — the same bargain Sonic Pi and TidalCycles
make — so a loop from elsewhere should be read before it is played.

## TuningFork.Tick

A loop's source runs again every round, so a `tick` in it gives 0 the first time round, 1
the second, and so on; with `TuningFork.Ring` that is how a line walks through a set of notes.
`tick/1` steps a counter and gives the value it stepped from; `look/1` gives the count without
stepping. `tick/0` uses the loop being run — inside a stage loop, the loop's own name — so each
loop counts on its own; `tick/1` names a counter directly, for two counters in one loop or one
shared between loops. Outside a loop the counter is `:default`. Counters live in
`TuningFork.Store`, so a piece is a function of how many times round it has been and plays the
same from a fresh store.

## TuningFork.SonicPi

Sonic Pi's model is a thread with a clock: `play` puts a note at the thread's time and
`sleep` moves the time on. Here that thread is a `TuningFork.SonicPi.Thread` kept in the
process dictionary, and every word of the vocabulary reads or writes it — which is what lets
`rrand`, `choose`, `tick` and `sleep` be bare expressions rather than functions threading a
part by hand. Time inside a thread is seconds; `use_bpm` only scales `sleep`, and the score
that comes out runs at 60 beats a minute.

A `live_loop` body is run once per round in a fresh thread: `Blocks.run_round/2` seeds the
thread's generator from the loop's name and the round's frame, so every round draws
differently and the same piece plays the same from a fresh `TuningFork.Store`;
`use_random_seed` resets the stream, which is why Sonic Pi code that seeds at the top of a
loop repeats each round exactly. A loop inherits the tempo, synth, defaults, transposition and
open effects of the thread that started it, so a `live_loop` inside `with_fx :reverb` sounds
through the reverb. `live_loop` cues its own name at the start of every round unless
`auto_cue: false`, and `sync:` waits for another loop's cue before the first round; `delay:`
makes the first round that many beats of silence.

`in_thread` runs its block now without moving the thread's time or its generator. `with_fx`
opens a segment: notes played inside carry the segment's effects, and `control` on the effect
starts a new segment for what follows, so a changed mix becomes a second layer in the score.
Nested effects are applied inner first. `control` on a note records the change against the
note and, when the round is scored, becomes a `TuningFork.Curve` on the voice — a step, or a
slide over `note_slide`/`amp_slide`/`cutoff_slide` seconds — with cutoff moving the voice's
`TuningFork.Filter` through its own curve in seconds.

`cue` writes to `TuningFork.State` and `sync` reads it: a round that syncs on a name not yet
cued is given up as waiting and the loop tries again next round, so `sync` gates the start of
a round rather than pausing inside one. A body that never sleeps is refused, since a loop of no
length cannot come round; a thread that runs past the loop's sleeps is cut at the round's
end. `stop` ends the round where it is.

`run/1` evaluates a buffer of source: top-level code becomes a score played once, running to
the end of its last note, and every `live_loop` is collected with the settings it inherited.
`render/4` plays a buffer offline through `TuningFork.Transport.render_rounds/4`;
`play_buffer/2` starts it on a stage.

Names that Sonic Pi has and this does not: `define` (write an Elixir `fn`), `at` scheduling
beyond `at times, args, fn`, `sync` waiting mid-round, per-note `pan_slide`, `pitch_shift`,
`octaver`, `ring_mod`, `vowel`, `autotuner` and `chorus` effects, and the `mod_*` synths'
square-wave pitch modulation, which is played as vibrato. Unknown options on `play`, `sample`
and `with_fx` are ignored, as are `use_debug`, `puts` and `print`.

Sonic Pi words that would collide with `TuningFork.Part`'s — `play`, `chord`, `pick`, `synth`,
`at` — take a `%TuningFork.Part{}` as their first argument and hand it to the part's function,
so a pipeline and a Sonic Pi block can sit in the same buffer.

## TuningFork.Strudel

A translator from the JavaScript written at strudel.cc to this library's chains, so a piece
is pasted rather than rewritten. It is a tokenizer, a recursive-descent parser for the
subset of JavaScript a Strudel piece uses — numbers, strings in any quote, identifiers,
calls, method chains that may continue on the next line with a dot, arrays, arrow
functions with zero to two parameters, `+ - * / %` and unary minus, `let`/`const`
assignments, `$:` labels, `//` and `/* */` comments, semicolons — and an emitter from that
tree to Elixir source. Object literals and anything else are refused with the line.

### The sounds a piece expects

strudel.cc registers a set of sample banks before any piece runs: its drum kit
(`uzu-drumkit`, where `bd`, `sd`, `hh`, `cp` and the rest come from), the drum machines
and the short names for them (`tr808_bd` for `RolandTR808_bd`, through `aliases/1`), the
Salamander piano, the VCSL orchestral set, the mridangam, and a handful of Dirt-Samples.
`defaults/0` registers the same sets from the same CDN, in the background the first time a
piece is read, without fetching a file; files come as they are played and
`TuningFork.Pattern.Player` prefetches the ones a pattern will need. The application
environment `:strudel_defaults` set to `false` turns it off, which the test suites do.

### What becomes a row

A `$:`-labelled statement is a row and `_$:` a silent one; a piece with no labels plays its
last expression. A `stack`, `cat`, `seq` or other list word at the top of a row is split
into one chain per voice, and the methods called on the stack are appended to every
voice's chain, so `stack(a, b).room(.3)` is `a |> room(0.3)` and `b |> room(0.3)`; nested
stacks flatten the same way. `let` variables are substituted into every chain that uses
them, which is what lets one `chords` pattern feed three voices. `setcps` and `setcpm`
are reported in the meta rather than emitted, `samples(...)` is loaded through
`TuningFork.Sample.Set` on the way through, and `hush()` and `await` are skipped.

### How a call is spelt

A method chain is a pipeline: `s("bd").gain(.5)` is `s("bd") |> gain(0.5)`. A string with a
method called on it is `mini("…")` first. A bare transformer in argument position —
`rarely(ply("2"))`, `chunk(4, fast(2))` — is a function of the pattern, `&(&1 |> ply("2"))`,
and a bare word there — `every(4, rev)` — is a function capture, `&rev/1`. `every` and
`when_cycle` take the pattern last, so they are emitted as `then(&every(4, f, &1))`. A
signal is a call, `sine()`. An arrow function is `fn x -> … end`. Strudel's spellings map
onto this library's through one alias table (`sound`→`s`, `sz`→`size`, `legato`→`clip`,
`hurry`→`fast`, `cat`→`slowcat`, `seq`→`fastcat`, camelCase→snake_case), and a word that is
neither a pattern nor a control function here is refused by name and line, so a piece
either plays as written or says which word it cannot.

### Where things came from

Each chain carries the first and last line of the statement it came from, counted from
zero, so `TuningFork.Session` can hang an error on the right row and draw a picture under
the last one. Parse errors carry the line of the token that stopped them.

## TuningFork.SonicPi.Names

A note is a MIDI number, a name with or without an octave (`:e3`, `:e`, `:Fs4`, `:Eb2`,
`"c4"`), or hertz as a float; a name without an octave is in octave 4, so `:c` is middle C,
and `note(:F, octave: 1)` moves it. Chords and scales come back as MIDI numbers, as they do
in Sonic Pi, so arithmetic on them works. Chord names include the short ones (`:m7`, `:M`,
`:dom7`, `:dim`, `:aug`, `"7"`) and scale names are Sonic Pi's set, sixty of them.

## TuningFork.SonicPi.Synth

Each Sonic Pi synth is a preset over `TuningFork.Voice`: a shape, a default lowpass as a MIDI
cutoff and a resonance from Sonic Pi's `synthinfo.rb`, and whatever extras the sound needs —
FM for the bells and the electric pianos, vibrato for the leads, crush for the chip sounds, a
filter envelope for the 303 and the pluck. Detuned synths (`dsaw`, `supersaw`, `tech_saws`,
`hoover`, `prophet`, `winwood_lead`, `dark_ambience`) are several voices spread by `:detune`
semitones; `subpulse` and `bass_foundation` add a sine an octave down; `organ_tonewheel` is
three harmonics. The `sc808_*` names are the kit's drums.

Sonic Pi's envelope is attack, decay, sustain (a time, not a level) and release, all in
seconds, with `sustain_level` for the held level; the default is a one-second release and
nothing else. `amp` 1 is normal and maps to a gain of 0.8; `cutoff` is a MIDI note; `res` from
0 to 1 becomes a filter `q` of `1 / (1 - res)`, held at 62. `divisor` and `depth` are the FM
ratio and depth. The `mod_*` synths' pitch modulation is played as vibrato at `1 / mod_phase`
hertz over half `mod_range` semitones.

## TuningFork.SonicPi.Effects

Each Sonic Pi effect becomes one or two `TuningFork.Fx` effects with Sonic Pi's option names
and defaults: `reverb`/`gverb`, `echo` (decay in seconds to fall 60 dB becomes a feedback of
`10^(-3 phase / decay)`), `slicer`, `wobble`, `ixi_techno` (a sine wobble), `panslicer`, `pan`,
`level`, `tremolo`, `bitcrusher` and `krush` (drive and a lowpass), `distortion`/`tanh`,
`compressor`, the six filter names, the four bandpass names and `flanger`. Cutoffs are MIDI
notes and resonance runs 0 to 1; an LFO `wave` is Sonic Pi's number, 0 saw to 3 sine. An
`amp:` on any effect appends a level. `reps:` on `with_fx` runs the block that many times.
