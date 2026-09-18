# tuning_fork_drafter design

The terminal front end for TuningFork. It is one of several front ends over the same headless
packages: this one draws with Drafter and plays through `tuning_fork_speaker`; the Livebook one
(`tuning_fork_kino`) draws with Kino and plays in a browser. Neither knows about the other,
and `tuning_fork_composer` knows about neither. The speaker dependency is optional: the
editors and the source they write work on a machine with no sound card, they are simply quiet.

Three apps live here. `TuningFork.ComposerApp` is a step sequencer over
`TuningFork.Composer`. `TuningFork.LiveCodeApp` live-codes mini-notation patterns, one a row,
swapped together at the cycle line. `TuningFork.LoopsApp` live-codes named loops, each an
independent block of Elixir with its own length and its own place in it. Each has a Mix task
that parses the command line into the map the app's `mount/1` takes.

## TuningFork.ComposerApp

The screen is a header, a settings line, a beat ruler, one row per track, a message line and
a footer:

    Compose
    96 bpm · 2 bars · 4/4 · a2 minor_pentatonic · gain 0.5
                 1           2           3           4
    ▸ kick      [█] ·  ·  ·  █  ·  ·  ·  █  ·  ·  ·  █  ·  ·  ·
      bass       1  ·  ·  ·  1  ▬  ▬  ·  4  ·  ·  ·  3  ·  ·  ·

`▸` marks the row the cursor is on and `[ ]` the step. `█` is a drum hit, a digit a scale
degree, `▬` a note held from an earlier step, `·` silence. A dimmed row is muted.

Mouse: clicking a step places a note there and moves the cursor to it; clicking a pitched
step again walks it up the scale; dragging right from a note holds it over the steps crossed;
the wheel over a step walks it up or down the scale. Notes are placed on `mouse_down`, not
`mouse_up`, so a click does not act twice on its way down and up.

Keys: arrows move the cursor; space places a note or takes it away; `+` `-` walk a pitched
note up and down the scale; `>` `<` hold a note one step longer or shorter; `m` mutes the
row; `c` empties it; `a` adds a row and `x` removes the current one; `k` cycles the row's kind
(drum, pitched, sample); `i` cycles its instrument; `p` plays or stops; `w` writes the source
out; `q` quits. Notes stop where the next one starts, so `>` and dragging both clamp.

Playing: `p` starts and `p` again stops, only ever one at a time. What plays is a render of
the grid as it was when `p` was pressed, looping on a `TuningFork.Stage` bed, so edits made
while it runs are not heard until it is stopped and started again. Quitting stops it. The
render is kept against the project it came from, so playing again after no edit is immediate;
rendering is proportional to the length of the piece (around half a second for sixteen bars)
and is paid on the first play and again after any edit. A live stage is asked to stop so it
closes the audio device on the way out, and is killed if it has not stopped within two seconds.
Playing needs `tuning_fork_speaker`; without it `p` says so and nothing else happens.

Drawing and hit-testing: the grid is drawn as text, so clicks are hit-tested by arithmetic
rather than by widgets. Three numbers have to agree between `render/1` and `hit/3`:
`label_width` (12 columns of row name before the grid), `cell_width` (3 columns per step) and
`rows_above/0` (3 rows drawn above the first track). Any line added above the grid in
`render/1` must be counted in `rows_above/0`, or every click lands on the wrong row.

The Drafter messages the app handles: `mount/1` receives the props as a map; key events are
`{:key, :q}`, `{:key, :left}`, `{:key, :+}` with the character as an atom; mouse events are
`{:mouse, %{type: type, x: x, y: y, button: _, mods: _}}` where `type` is `:mouse_down`,
`:mouse_up`, `:move` or `:scroll` and a `:scroll` also carries `:direction`; `x` and `y` are
zero-based from the top left; `update/2` returns the new state or `{:stop, reason}`.

What `w` writes is ordinary `TuningFork.Part` source with no dependency on the composer: it
runs with `mix run` or can be pasted into a project.

## TuningFork.LiveCodeApp

One pattern a row, as many rows as are written. Editing a row and pressing `Ctrl+E` makes it
take over at the next cycle line; nothing stops. Moving down onto the last empty row adds
another, so there is no fixed number of rows to run out of; `room/1` keeps `spare/0` empty rows
below the last one in use.

    1 ▸ bd*4
    2   hh*8?
    3   ~ sn ~ sn
    4   _ n("<0 4 0 9 7>*16") |> scale("g:minor")

A slot starting `--`, `//` or `_` is off; any of the three in front of a line parks it.
Everything else is stacked and played together. `Tab` puts a marker on and takes it off
again, whichever of the three is there. An off slot is not played, drawn or checked, so a
line parked with `_` never reports an error however broken the rest of it is. The markers
are listed longest first so the longest match wins.

A row beginning `|>` carries on the row above it, so a chain too long for one line can be
written down the screen the way it reads:

    1  n("<0 4 0 9 7>*16")
    2  |> scale("g:minor")
    3  |> acid(0.55)

Those rows are one source as far as playing, drawing and error reporting go. `joined/1`
folds them into `{first_row, last_row, source}`; the picture is hung on the last row, under
the whole chain. A continuation with nothing above it is dropped rather than run on its own.
`Enter` splits a row at the cursor and `Backspace` at the start of a row joins it to the one
above, which is how chains get written and unwritten.

Slots that read as Strudel are translated whole by `TuningFork.Session`, so a piece pasted
from strudel.cc plays as written; evaluating also takes the tempo its `setcps` sets, through
the same path as the speed keys.

Keys: any character types into the slot; `←` `→` `Home` `End` move along the line; `↑` `↓`
move between slots; `Backspace` and `Delete` rub out; `Enter` breaks the line in two; `Tab`
comments the slot out or back in; `Ctrl+E` evaluates at the next cycle; `Ctrl+R` evaluates
now; `Ctrl+P` or clicking the transport line plays and pauses; clicking a row puts the cursor
there, mid-line; `Alt+.` `Alt+,` or `Ctrl+F` `Ctrl+D` go faster and slower; `Ctrl+K` empties
the slot; `?` shows the names and notation a slot may use; `Ctrl+Q` quits.

Evaluating parses every slot and records an error on the ones that will not parse. Slots that
will not parse are left out of the stacked pattern rather than failing the lot, so one bad
line does not silence the rest, and a slot showing an error keeps playing whatever it played
before, so a half-typed edit never drops out. The stage is started on the first evaluation and
updated afterwards, at the cycle line or immediately.

Drawing: a row draws nothing unless it asks. Ending a chain with `pianoroll()` or `scope()`
gets it a picture under its last line: a raster where the terminal can draw pixels, blocks
of text where it cannot. This follows `._pianoroll()` and `._scope()` in Strudel. A scope
traces the row it is written under, rendered from that row alone rather than read off the
speakers. The token sounding right now is bracketed in the line (`~ [cp] ~ cp`,
`<0 [4] 0 9 7>`), and in a pianoroll the note sounding is drawn hollow. `decorate/3` adds
the brackets and the cursor bar in one pass, so a caret inside the sounding token lands in the
right place rather than being pushed along by the brackets; `columns/3` is its inverse and
maps a click's screen column back to an index in the source.

A row that asks to be drawn is redrawn as the playhead moves, which costs a picture sent to
the terminal each time, so asking for one row is smooth and asking for eight is not. Rasters
are built only for slots that are switched on and ask, so a session with two rows running
sends the terminal two images and not eight.

The pictures carry no playhead of their own. `drawn_for/1` truncates the cycle to a whole
number, so every position inside one cycle builds the same picture term, and Drafter, which
regenerates a widget's image only when its state changes, sends the terminal nothing. That
is what keeps the pictures still; the playhead moves along the text ruler instead, which
costs nothing to redraw.

Drum hits are drawn as marks rather than stretched to the next hit. Bars drawn to their full
length butt up against each other and read as one solid block: four hits a cycle and two hits
a cycle would both fill the row. `hit_width/1` caps a hit at an eighth of a cycle and shortens
it to leave a gap. `View.widths/2` gives a hit's width in columns; the app converts it to
cycles by dividing by the number of columns.

Redrawing: paused, the screen is not redrawn at all, so there is no clock, no images and no
flicker while typing. Playing, the pictures are rebuilt on a 60 ms tick rather than every
frame. Building a raster means parsing every drawn row, walking its events and, for a scope,
synthesising audio; doing that in the app's own process would sit between a keystroke and the
screen and make typing lag behind the music, so `draw_elsewhere/1` does it in a spawned,
monitored process that sends `{:drawn, rasters}` back. Only one runs at a time; a tick
arriving while the last is still going is dropped rather than queued, so a slow frame costs a
frame and never builds a backlog. The monitor matters: a drawer that dies never sends
`{:drawn, _}`, and the `:DOWN` message is what clears the `drawing` flag so the app does not
wait forever.

Tracing: there is no way to print from a terminal app, since the screen belongs to the
drawing. When the pictures are not keeping up with the music, running with
`TUNING_FORK_TRACE=/tmp/live.log` makes `trace/1` append to that file. Every tick records the
cycle it read and whether the last frame was still being built; every frame records how long
it waited to be scheduled and how long it took. A tick that says `drawing=true` was dropped,
which is the thing to look for.

Pixels are detected once at mount. `pixels: false` in the props forces the text drawing,
which is what the tests use so that what they assert on does not depend on the terminal they
run in.

The help screen's drum list comes from `TuningFork.Kit.families/0`, so it cannot drift from
what the kit will actually play.

Sound needs `tuning_fork_speaker`. Without it the app still runs and still shows the
punchcards; it says so instead of playing.

## TuningFork.LoopsApp

Where `LiveCodeApp` edits patterns, all stacked and swapped together at the cycle line, this
edits loops in the manner of Sonic Pi: independent blocks of Elixir, each with its own name,
its own length and its own place in it. A four-bar bass line and a three-bar melody can run at
once without either being stretched to fit, because neither is waiting for the other's cycle
line to come round, only its own.

    drums ▸ part(bpm: 120, synth: Kit.voice("bd", 0.3))
            |> play(:c3, 1) |> play(:c3, 1)
            round 7 · beat 1.5

    bass    part(bpm: 120, synth: Kit.voice(%{note: "c2", shape: :saw}, 0.4))
            |> play(:c2, 2) |> play(:g2, 2)
            round 3 · beat 0.5 · waiting

A loop's source is Elixir text, possibly several lines, written with `TuningFork.Part`'s DSL,
that must evaluate to a `TuningFork.Score` or a `TuningFork.Part`. A bare part is wrapped in
a score automatically, since `TuningFork.Part.play/4` is what most loops are written with.
Unlike `LiveCodeApp`'s slots, a loop's source is kept as a single string with embedded
newlines rather than a list of rows: there is no `|>`-continuation convention to parse, since
the whole block already belongs to one loop, and `Enter` inserts a newline where the cursor
is. `position/2` and `offset_of/3` convert between a cursor offset and `{row, column}` for
drawing and for vertical movement.

Continuation lines and the status line are indented by the name's width plus three: the
name, a space, the marker and the space after it, which is what the first line's own prefix
takes up, so everything underneath lines up with where the source begins. A click's source
column is worked out from the outer padding (1) plus that prefix.

Evaluating: `Ctrl+E` evaluates the current loop; the new score takes over when the loop next
comes round (`Stage.update_loop/4` with `at: :round`), which keeps an edit from landing halfway
through a bar. `Ctrl+R` takes over on the next chunk instead. A loop not yet running is started
outright either way, since there is no round to wait for on something silent. Source that will
not evaluate reports the reason underneath and changes nothing already sounding: the stage
keeps playing whatever it was handed last, because the app never sends it the broken score.
The app also keeps its own copy of the last score that did evaluate, so `Ctrl+P` can bring
every loop back after a pause without losing anything to a half-typed edit made in between.

Adding and naming: `Ctrl+N` adds a loop auto-named `loop1`, `loop2`, … skipping names already
taken, opening on `template/0`, a four-beat drum part that plays as it stands. `F2`, or
`Ctrl+T` where the function row is spoken for, renames the loop under the cursor; `Enter`
keeps the name, `Esc` cancels. A rename takes the sound with it, stopping the old name on the
stage and starting the loop again under the new one. A blank name, or one another loop already
holds, is refused and said so.

Keys: any character types into the current loop at the cursor; `←` `→` `↑` `↓` `Home` `End`
move around its source; `Backspace` and `Delete` rub out; `Enter` breaks the line; `Ctrl+E`
evaluates at the round; `Ctrl+R` evaluates now; `Ctrl+N` adds a loop; `F2` or `Ctrl+T`
renames; `Ctrl+X` stops the current loop; `Tab` comments the loop out or back in, and
commenting it out stops it; `Ctrl+P` or clicking the summary line plays and pauses everything;
clicking a loop puts the cursor there; `?` shows the keys and the DSL; `Ctrl+Q` quits. A fresh
loop's cursor starts at the very end of its source, so a selected loop's last line carries the
cursor mark there.

Sound needs `tuning_fork_speaker`; without it the app still edits and shows what each loop
would play, and says so instead of playing. A stage can also be handed in through the `:stage`
or `:sink` props. A stage or sink given to `mount/1` counts as playable even before a stage
exists, since `ensure_stage/1` builds one from it on demand. This is how tests exercise the
real `TuningFork.Stage` wiring without a sound device: `:stage` lets a test assert on the
stage directly, and `:sink` set to `TuningFork.Sink.Silent` gives a real stage with nowhere
for the sound to go.

## TuningFork.Drafter.Paint

Every function is pure and returns a `FrenchCurve.Raster`, so what gets drawn can be asserted
on as pixels without a terminal.

In a pianoroll, notes are drawn as bars the length they sound, so a held note reads as held
rather than as a dot. The pitch range is whatever the events cover, padded a little so the
top and bottom rows are not flush against the edge. The note sounding right now is drawn as
an outline rather than filled, so the eye can find it without following the playhead line.
`playhead: false` leaves the line out but does not make the picture still: which note is
hollow still follows the phase.

Unpitched hits get `hits/3`, bars the full height of the raster. A pianoroll would put every
hit on one line, which at the size a row is drawn comes out as a hairline; a bar that fills
the height reads at a glance.

A scope with an empty sample list draws the zero line alone rather than nothing, so the pane
does not flicker between frames.

## TuningFork.Drafter.Roll

A Drafter widget that draws a raster where the terminal can show pixels and falls back to
lines of text where it cannot. The caller decides how tall the pane is; the raster is fitted
to it.

Registration asks `function_exported?(module, :component_tag, 0)`, which is false for a module
the VM has not loaded, so the widget must be loaded with `Code.ensure_loaded!/1` before
Drafter's widget registry; registering an unloaded widget quietly registers nothing.

`update/2` uses a key present in the props even when its value is `nil`, so a raster can be
taken away again; an absent key leaves that part of the state as it was.

`FrenchCurve.frame/3` decides how the picture is actually sent. The two kitty dialects differ:
a terminal that keeps images under an id stores the image once and places it again without
resending, while a terminal answering to kitty without stored images needs the other dialect.
Nothing detects the second kind today; the tests reach it by forcing the protocol, and the
dialect still has to be right for that terminal. iTerm is detected as kitty but does not
support placements.

## Mix.Tasks.TuningFork.Compose

Parses `--bpm`, `--bars`, `--meter`, `--division`, `--gain`, `--key`, `--scale`, `--name`,
`--empty` and `--out` into the map `TuningFork.ComposerApp.mount/1` takes. A meter of 3 is a
waltz; a division of 3 is triplets and 8 is thirty-seconds. Without `--empty` the editor opens
on `TuningFork.Composer.demo/0`.

Drafter reads mount props from the `:props` key of the options given to `Drafter.run/2` and
ignores everything else, so the map is passed as `props: props(argv)` and never spread across
the top level. `argv` is parsed strictly, so an unknown switch raises rather than being
ignored.

The task cannot be run from a test because it takes over the terminal. What
`test/compose_task_test.exs` checks is the map the task builds, put through Drafter's own prop
reading, so a flag proved to reach `mount/1` in the test also reaches it in a terminal.

## Mix.Tasks.TuningFork.Live

Parses `--cps` (default 0.5, one cycle every two seconds), repeatable `--pattern`, and
`--text` into the map `TuningFork.LiveCodeApp.mount/1` takes, and registers
`TuningFork.Drafter.Roll` after loading it. See `TuningFork.Pattern.Mini` for the notation.

## Mix.Tasks.TuningFork.Loops

Parses repeatable `--loop NAME=SOURCE` into the map `TuningFork.LoopsApp.mount/1` takes.
Without one the demo loops are used: a drum loop and a bass loop, both four beats long.

## Drafter, as used here

What this application relies on in drafter's API:

- Props go under `:props` — `Drafter.run(App, props: %{project: p})`; options at the top
  level are not props
- `mount/1` receives props as a **map**, not a keyword list
- Mouse events are `{:mouse, %{type: type, x: x, y: y, button: _, mods: _}}`
- `type` is `:mouse_down`, `:mouse_up`, `:move` or `:scroll`; `:scroll` also carries
  `:direction`
- `x` and `y` are **zero-based** from the top left
- Key events are `{:key, :q}`, `{:key, :left}`, `{:key, :+}` — the character as an atom
- `update/2` returns the new state, or `{:stop, reason}` to quit
- Widget helpers used here: `vertical/2`, `label/2`, `header/1`, `footer/1`
