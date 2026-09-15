defmodule TuningFork.LiveCodeApp do
  @moduledoc """
  Live coding mini-notation patterns in a terminal, one pattern a row, swapped at the cycle
  line.

      mix tuning_fork.live
  """

  use Drafter, runtime: :reducer

  alias TuningFork.Drafter.Paint
  alias TuningFork.{Kit, Pattern, Scale, Session}
  alias TuningFork.Session.View

  @spare 3
  @steps 32
  @tick 60
  @roll_height 4
  @pad 1

  @type t :: %{
          slots: [map()],
          slot: non_neg_integer(),
          stage: pid() | nil,
          sink: module() | nil,
          cycle: float(),
          level: float(),
          help: boolean(),
          cps: float(),
          pixels: boolean(),
          playing: boolean(),
          rasters: map(),
          drawing: boolean(),
          said: String.t()
        }

  @doc """
  The state the editor starts in.

  `props` is a map or a keyword list: `:patterns` a list of mini-notation strings (default
  `demo/0`), `:cps` cycles per second (default `0.5`), `:pixels` whether to draw rasters
  (default `pixels?/0`), `:stage` an already-running `TuningFork.Stage` used as given,
  `:sink` a `TuningFork.Sink` module used when the app starts its own stage, in place of
  checking for a speaker.
  """
  @impl true
  @spec mount(map() | keyword()) :: t()
  def mount(props) do
    props = Map.new(props)

    given = Map.get(props, :patterns, demo())
    sources = given ++ List.duplicate("", max(@spare - 1, 0))

    state = %{
      slots: Enum.map(sources, &slot/1),
      slot: 0,
      stage: Map.get(props, :stage),
      sink: Map.get(props, :sink),
      cycle: 0.0,
      level: 0.0,
      help: false,
      cps: Map.get(props, :cps, 0.5) / 1.0,
      pixels: Map.get(props, :pixels, pixels?()),
      playing: true,
      rasters: %{},
      drawing: false,
      said:
        "ctrl+e evaluates · enter splits · tab comments out · ctrl+p pause · ? keys · ctrl+q quit"
    }

    schedule()

    start(state)
  end

  @doc "The patterns a fresh session opens on."
  @spec demo() :: [String.t()]
  def demo do
    [
      "s(\"bd!4\") |> scope()",
      "hh*8?0.2",
      "~ cp ~ cp",
      "n(\"<0 4 0 9 7>*16\")",
      "|> scale(\"g:minor\") |> transpose(-12) |> shape(:saw)",
      "|> cutoff(220) |> resonance(16)",
      "|> lpenv(2.7) |> lpsustain(0.1) |> lpdecay(0.14)",
      "|> pianoroll()",
      "-- n(\"<0>*8\") |> scale(\"g:minor\") |> transpose(-24) |> shape(:saw)"
    ]
  end

  defp slot(source), do: %{source: source, cursor: String.length(source), error: nil}

  defp schedule, do: Process.send_after(self(), :tick, @tick)

  @doc """
  Append `line`, prefixed with the monotonic time in milliseconds, to the file named by the
  `TUNING_FORK_TRACE` environment variable. Does nothing when the variable is unset.

      TUNING_FORK_TRACE=/tmp/live.log mix tuning_fork.live
  """
  @spec trace(String.t()) :: :ok
  def trace(line) do
    case System.get_env("TUNING_FORK_TRACE") do
      nil ->
        :ok

      path ->
        at = System.monotonic_time(:millisecond)

        File.write(path, "#{at} #{line}\n", [:append])
        :ok
    end
  end

  defp ms(microseconds), do: "#{div(microseconds, 100) / 10}ms"

  @doc false
  @impl true
  def update(message, state)

  def update(:tick, %{playing: false} = state), do: state

  def update(:tick, state) do
    schedule()

    {cycle, level} = reading(state)

    trace("tick cycle=#{Float.round(cycle, 3)} drawing=#{state.drawing}")

    %{state | cycle: cycle, level: level} |> draw_elsewhere()
  end

  def update({:drawn, rasters}, state) do
    %{state | rasters: rasters, drawing: false}
  end

  def update({:DOWN, _ref, :process, _pid, _reason}, state), do: %{state | drawing: false}

  def update({:key, :p, [:ctrl]}, state), do: toggle(state)

  def update({:key, :"?"}, state), do: %{state | help: not state.help}

  def update({:key, :q, [:ctrl]}, state), do: quit(state)

  def update({:key, :e, [:ctrl]}, state), do: evaluate(state, :cycle)
  def update({:key, :r, [:ctrl]}, state), do: evaluate(state, :now)

  def update({:key, :enter, [:ctrl]}, state), do: evaluate(state, :cycle)
  def update({:key, :enter}, state), do: split(state)

  def update({:key, :k, [:ctrl]}, state),
    do: state |> put_source("", 0) |> Map.put(:said, "emptied")

  def update({:key, :., mods}, state) when mods != [], do: speed(state, state.cps * 1.25)
  def update({:key, :",", mods}, state) when mods != [], do: speed(state, state.cps / 1.25)
  def update({:key, :f, [:ctrl]}, state), do: speed(state, state.cps * 1.25)
  def update({:key, :d, [:ctrl]}, state), do: speed(state, state.cps / 1.25)

  def update({:key, :tab}, state), do: comment(state)

  def update({:key, :up}, state), do: %{state | slot: max(state.slot - 1, 0)}

  def update({:key, :down}, state) do
    %{state | slot: state.slot + 1} |> room()
  end

  def update({:mouse, %{type: :mouse_down, x: x, y: y}}, state) do
    case spot(state, x, y) do
      :transport -> toggle(state)
      {index, nil} -> %{state | slot: index}
      {index, column} -> %{state | slot: index} |> put_cursor(column)
      nil -> state
    end
  end

  def update({:key, :left}, state), do: move(state, -1)
  def update({:key, :right}, state), do: move(state, 1)
  def update({:key, :home}, state), do: put_cursor(state, 0)
  def update({:key, :end}, state), do: put_cursor(state, String.length(current(state).source))

  def update({:key, :backspace}, %{slot: at} = state) when at > 0 do
    if current(state).cursor == 0, do: join(state), else: rub_out(state)
  end

  def update({:key, :backspace}, state), do: rub_out(state)
  def update({:key, :delete}, state), do: state |> move(1) |> rub_out()

  def update({:key, key}, state) when is_atom(key) do
    case Atom.to_string(key) do
      <<_char::utf8>> = text -> insert(state, text)
      _longer -> state
    end
  end

  def update({:char, codepoint}, state), do: insert(state, <<codepoint::utf8>>)

  def update(_anything_else, state), do: state

  @doc false
  @impl true
  def render(state) do
    vertical(
      [
        header("Live"),
        label(status(state), style: %{fg: :cyan}),
        vertical(body(state), flex: 1),
        footer(state.said)
      ],
      padding: 1
    )
  end

  defp body(%{help: true}), do: help_rows()

  defp body(state) do
    Enum.flat_map(0..(length(state.slots) - 1), &rows(state, &1))
  end

  @doc "How many rows `render/1` draws above the first slot: the padding, header and transport line."
  @spec rows_above() :: non_neg_integer()
  def rows_above, do: 3

  @doc "The row the transport line is drawn on, which is the one that plays and pauses."
  @spec transport_row() :: non_neg_integer()
  def transport_row, do: 2

  @doc """
  What a click at `x`, `y` landed on: `:transport` for the play line, `{slot, column}` for a
  click in a row's text, `{slot, nil}` for a click on the picture underneath one, and `nil`
  for anywhere else. `x` and `y` are zero-based from the top left. `column` is an index into
  the row's source, not a screen column.
  """
  @spec spot(t(), non_neg_integer(), non_neg_integer()) ::
          :transport | {non_neg_integer(), non_neg_integer() | nil} | nil
  def spot(state, x, y)

  def spot(%{help: true}, _x, _y), do: nil

  def spot(_state, _x, y) when y == 2, do: :transport

  def spot(state, x, y) do
    Enum.find_value(layout(state), fn {index, top, height} ->
      cond do
        y == top -> {index, clicked(state, index, x)}
        y > top and y < top + height -> {index, nil}
        true -> nil
      end
    end)
  end

  @doc """
  Every slot, as `{index, first row, how many rows}`. A slot's rows are its line of text,
  whatever it draws underneath, and an error line if it has one.
  """
  @spec layout(t()) :: [{non_neg_integer(), non_neg_integer(), pos_integer()}]
  def layout(state) do
    state.slots
    |> Enum.with_index()
    |> Enum.map_reduce(rows_above(), fn {slot, index}, top ->
      height = 1 + drawn_height(state, slot, index) + length(error_row(slot))

      {{index, top, height}, top + height}
    end)
    |> elem(0)
  end

  defp drawn_height(state, slot, index) do
    cond do
      not state.pixels -> length(written(slot, state.cycle))
      is_nil(drawn(state, index)) -> 0
      true -> @roll_height
    end
  end

  defp clicked(state, index, x) do
    slot = Enum.at(state.slots, index)
    caret = if index == state.slot, do: slot.cursor
    into = x - @pad - String.length("#{index + 1}") - 3

    slot.source
    |> columns(caret, sounding(slot, state.cycle))
    |> Enum.min_by(fn {_at, column} -> abs(column - into) end)
    |> elem(0)
  end

  @doc """
  Where every character of `source` ends up on screen once `decorate/3` has added its
  brackets and cursor bar, as `{index in the source, column}`. `caret` and `span` are as for
  `decorate/3`. There is one more pair than there are characters, for the position past the
  end.

      iex> TuningFork.LiveCodeApp.columns("bd", nil, {0, 1})
      [{0, 1}, {1, 3}, {2, 4}]
  """
  @spec columns(String.t(), non_neg_integer() | nil, {integer(), integer()} | nil) ::
          [{non_neg_integer(), non_neg_integer()}]
  def columns(source, caret, span) do
    {from, to} = span || {-1, -1}
    characters = String.graphemes(source)

    {pairs, width} =
      characters
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {_character, at}, column ->
        opens = count(at == caret) + count(at == from)

        {{at, column + opens}, column + opens + 1 + count(at + 1 == to)}
      end)

    pairs ++ [{length(characters), width}]
  end

  defp count(true), do: 1
  defp count(false), do: 0

  @doc """
  Start building this frame's rasters in a spawned, monitored process that sends
  `{:drawn, rasters}` back when finished. Returns the state with `:drawing` set. While a build
  is running the call is a no-op.
  """
  @spec draw_elsewhere(t()) :: t()
  def draw_elsewhere(%{drawing: true} = state), do: state

  def draw_elsewhere(state) do
    back = self()
    asked = %{state | rasters: %{}}
    cycle = state.cycle

    asked_at = System.monotonic_time(:microsecond)

    spawn_monitor(fn ->
      began = System.monotonic_time(:microsecond)
      built = rasters(asked, cycle)
      done = System.monotonic_time(:microsecond)

      trace("built #{map_size(built)} wait=#{ms(began - asked_at)} work=#{ms(done - began)}")

      send(back, {:drawn, built})
    end)

    %{state | drawing: true}
  end

  @doc """
  Break the current row in two at the cursor. What is behind the cursor stays; what is in
  front of it starts a new row below, with the cursor at its beginning.
  """
  @spec split(t()) :: t()
  def split(state) do
    slot = current(state)
    {stays, goes} = String.split_at(slot.source, slot.cursor)

    slots =
      state.slots
      |> List.replace_at(state.slot, %{slot | source: stays})
      |> List.insert_at(state.slot + 1, %{source: goes, cursor: 0, error: nil})

    room(%{state | slots: slots, slot: state.slot + 1})
  end

  @doc """
  Put the current row onto the end of the one above, with the cursor where the two meet. The
  first row is left alone.
  """
  @spec join(t()) :: t()
  def join(%{slot: 0} = state), do: state

  def join(state) do
    above = Enum.at(state.slots, state.slot - 1)
    here = current(state)

    slots =
      state.slots
      |> List.replace_at(state.slot - 1, %{
        above
        | source: above.source <> here.source,
          cursor: String.length(above.source)
      })
      |> List.delete_at(state.slot)

    %{state | slots: slots, slot: state.slot - 1}
  end

  @doc "Add empty rows until at least `spare/0` sit below the last one with anything in it."
  @spec room(t()) :: t()
  def room(state) do
    used =
      state.slots
      |> Enum.with_index()
      |> Enum.filter(fn {slot, _index} -> String.trim(slot.source) != "" end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.max(fn -> -1 end)

    wanted = max(used, state.slot) + spare()
    short = wanted - length(state.slots) + 1

    if short > 0 do
      %{state | slots: state.slots ++ Enum.map(1..short, fn _ -> slot("") end)}
    else
      state
    end
  end

  @doc "How many empty rows are kept below the last one in use."
  @spec spare() :: pos_integer()
  def spare, do: @spare

  defp status(state) do
    playing =
      cond do
        not state.playing -> "❙❙"
        state.stage -> "▶ "
        true -> "· "
      end

    "#{playing} cycle #{:erlang.float_to_binary(state.cycle, decimals: 2)} · " <>
      "#{:erlang.float_to_binary(state.cps, decimals: 2)} cps · " <>
      "#{Enum.count(state.slots, &live?/1)} on"
  end

  defp rows(state, index) do
    slot = Enum.at(state.slots, index)
    here? = index == state.slot

    [label(line(slot, index, here?, state.cycle), style: %{fg: colour(slot, here?)})] ++
      drawing(state, slot, index, state.cycle) ++ error_row(slot)
  end

  defp drawing(state, slot, index, cycle) do
    cond do
      not state.pixels ->
        written(slot, cycle)

      is_nil(drawn(state, index)) ->
        []

      true ->
        [
          {:tuning_fork_roll,
           [id: {:roll, index}, raster: drawn(state, index), height: @roll_height]}
        ]
    end
  end

  defp drawn(state, index) do
    case Map.get(state.rasters, index) do
      {_slot, _settled, raster} -> raster
      nil -> nil
    end
  end

  @doc """
  A raster for every switched-on slot that asks to be drawn, keyed by the index of the chain's
  last row. Each value is `{source, cycle, raster}`.
  """
  @spec rasters(t(), float()) :: %{non_neg_integer() => FrenchCurve.Raster.t()}
  def rasters(state, cycle) do
    state.slots
    |> joined()
    |> Enum.filter(fn {_first, _last, source} -> asks?(source) end)
    |> Map.new(fn {_first, last, source} ->
      {last, {source, cycle, picture(state, source, cycle)}}
    end)
    |> Map.reject(fn {_index, {_source, _cycle, raster}} -> is_nil(raster) end)
  end

  defp picture(state, slot, cycle) do
    case asks?(slot) do
      :scope -> Paint.scope(samples(slot, cycle, state.cps), width: 256, height: 40)
      :pianoroll -> raster(slot, cycle)
      _none -> nil
    end
  end

  @doc "A window of this row's own sound, from -1.0 to 1.0. See `TuningFork.Session.View.scope/3`."
  @spec samples(map() | String.t(), number(), number()) :: [float()]
  def samples(slot, cycle, cps), do: View.scope(slot, cycle, cps)

  @doc "How tall a trace is drawn after the note that made it. See `TuningFork.Session.View.fade/2`."
  @spec fade(number(), number()) :: float()
  defdelegate fade(cycles, cps), to: View

  @doc "Where the last note before `cycle` began. See `TuningFork.Session.View.struck/2`."
  @spec struck(Pattern.t(), number()) :: float()
  defdelegate struck(pattern, cycle), to: View

  @doc """
  What a slot has asked to be drawn as: `:pianoroll`, `:scope`, or `nil` for a row ending in
  neither.

      iex> TuningFork.LiveCodeApp.asks?(%{source: "bd*4"})
      nil
  """
  @spec asks?(map() | String.t()) :: :pianoroll | :scope | nil
  defdelegate asks?(slot), to: Session

  @doc """
  Which cycle a picture is drawn for: the whole number, not the position within it.

      iex> TuningFork.LiveCodeApp.drawn_for(4.99)
      4
  """
  @spec drawn_for(number()) :: integer()
  def drawn_for(cycle), do: trunc(cycle)

  defp written(slot, cycle) do
    case pianoroll(slot, cycle) do
      [] -> [label("    " <> punchcard(slot, cycle), style: %{fg: :bright_black})]
      rows -> Enum.map(rows, &label("    " <> &1, style: %{fg: :cyan}))
    end
  end

  @doc """
  A slot's cycle as a raster: a pianoroll for a pitched slot, a row of hit bars for anything
  else, both with the playhead drawn through them. `nil` for a slot with nothing in it.
  """
  @spec raster(map(), float()) :: FrenchCurve.Raster.t() | nil
  def raster(slot, cycle) do
    case events(slot, cycle) do
      [] ->
        nil

      found ->
        pitched =
          for {column, value} <- found, note = Kit.midi(value), do: {column / @steps, note}

        size = [width: 256, height: 40]

        if pitched == [] do
          Paint.hits(struck(found, slot, cycle), cycle, size)
        else
          Paint.pianoroll(widths(pitched, slot, cycle), cycle, size)
        end
    end
  end

  defp struck(found, slot, cycle) do
    lengths = sounded(slot, cycle)

    for {column, _value} <- found do
      from = column / @steps
      held = Map.get(lengths, column, 1 / @steps)

      {from, from + hit_width(held)}
    end
  end

  @doc """
  How wide a drum hit is drawn, in cycles, given how long it sounds for: capped at an eighth
  of a cycle and shortened to leave a gap.

      iex> TuningFork.LiveCodeApp.hit_width(0.5) < 0.5
      true
  """
  @spec hit_width(number()) :: float()
  def hit_width(held), do: min(held, 0.125) * 0.7

  defp widths(pitched, slot, cycle) do
    lengths = sounded(slot, cycle)

    for {from, note} <- pitched do
      {from, from + Map.get(lengths, trunc(from * @steps), 1 / @steps), note}
    end
  end

  defp sounded(slot, cycle) do
    sounded_from(playable(slot), cycle)
  end

  defp sounded_from(nil, _cycle), do: %{}

  defp sounded_from(source, cycle) do
    source |> View.widths(cycle) |> Map.new(fn {column, wide} -> {column, wide / @steps} end)
  end

  defp line(slot, index, here?, cycle) do
    marker = if here?, do: "▸", else: " "
    caret = if here?, do: slot.cursor, else: nil

    "#{index + 1} #{marker} #{decorate(slot.source, caret, sounding(slot, cycle))}"
  end

  @doc """
  Where in a row's text the thing sounding at `cycle` was written, as `{from, to}`. In a row
  of code the first quoted string is read and the answer offset to where it sits in the line.
  `nil` for a parked row, a row that will not parse, or a moment when nothing sounds.

      iex> TuningFork.LiveCodeApp.sounding(%{source: "~ cp ~ cp"}, 0.3)
      {2, 4}
  """
  @spec sounding(map(), number()) :: {non_neg_integer(), non_neg_integer()} | nil
  defdelegate sounding(slot, cycle), to: View

  @doc """
  A row's text with the caret shown and the sounding token bracketed. `caret` is the cursor
  index, or `nil` on a row not being edited. `span` is what `sounding/2` found, or `nil`.

      iex> TuningFork.LiveCodeApp.decorate("~ cp ~ cp", nil, {2, 4})
      "~ [cp] ~ cp"
  """
  @spec decorate(
          String.t(),
          non_neg_integer() | nil,
          {non_neg_integer(), non_neg_integer()} | nil
        ) ::
          String.t()
  def decorate(source, caret, span) do
    {from, to} = span || {-1, -1}
    characters = String.graphemes(source)

    marked =
      for {character, at} <- Enum.with_index(characters), into: "" do
        opened = if at == from, do: "[", else: ""
        closed = if at + 1 == to, do: "]", else: ""
        here = if at == caret, do: "▏", else: ""

        here <> opened <> character <> closed
      end

    if caret != nil and caret >= length(characters), do: marked <> "▏", else: marked
  end

  defp colour(slot, true), do: if(slot.error, do: :red, else: :white)
  defp colour(slot, false), do: if(live?(slot), do: :green, else: :bright_black)

  defp error_row(%{error: nil}), do: []
  defp error_row(%{error: error}), do: [label("    " <> error, style: %{fg: :red})]

  @doc "The help text `?` shows, as lines: the names and notation a slot may use, and the keys."
  @spec reference() :: [String.t()]
  def reference do
    drums =
      Enum.map(Kit.families(), fn {family, sounds} ->
        names = Enum.map_join(sounds, "  ", fn group -> Enum.join(group, "/") end)

        "  #{String.pad_trailing(to_string(family), 12)}#{names}"
      end)

    [
      "Drums — the name is the sound, :n after it shifts the pitch",
      "" | drums
    ] ++
      [
        "",
        "  banks       " <> Enum.join(Kit.banks(), "  "),
        "",
        "Notes — letter, s for sharp or b for flat, then the octave",
        "",
        "  c0 to b8      c3  fs4  eb2  a4 is 440 Hz",
        "  60            a whole number is a midi note",
        "  440.0         a number with a point is hertz",
        "",
        "Notation",
        "",
        "  bd sn hh      in order, sharing the cycle",
        "  ~             a rest",
        "  [bd sn]       one step, subdivided",
        "  <bd sn>       one per cycle, in turn",
        "  bd*4  bd/2    faster, slower",
        "  bd!3  bd@3    repeated, given more room",
        "  bd?  bd?0.3   dropped at random",
        "  bd(3,8)       euclidean, hits and steps",
        "",
        "Off — put one in front of a line to park it",
        "",
        "  -- // _        any of the three · tab toggles",
        "",
        "Keys",
        "",
        "  ctrl+e         evaluate, in at the next cycle",
        "  ctrl+r         evaluate now",
        "  enter          break the line in two",
        "  backspace      at the start of a line, join it to the one above",
        "  ctrl+p         play and pause · or click the top line",
        "  alt+. alt+,    faster and slower",
        "  ctrl+f ctrl+d  the same, where alt is not sent",
        "  ctrl+k         empty this line",
        "  ctrl+q         quit",
        "  [bd*4, hh*8]  at the same time",
        "",
        "Code — a slot starting s( n( note( stack( is Elixir",
        "",
        "  n(\"0 4 7\")            degrees of a scale",
        "  s(\"bd*4\")             sounds",
        "  note(\"c3 g3\")         notes by name",
        "",
        "  .scale(\"g:minor\")     which scale the degrees are in",
        "  .transpose(-12)       semitones up or down",
        "  .octave(3)            which octave the scale sits in",
        "  .shape(:saw)          sine saw square triangle noise",
        "  .gain(.6) .pan(-.3)   how loud, and where",
        "  .acid(.546)           the 303 squelch, one knob",
        "  .pianoroll() .scope() ask for this row to be drawn",
        "",
        "Long chains — a row starting |> carries on the one above",
        "",
        "  n(\"<0 4>*8\")",
        "  |> scale(\"g:minor\") |> acid(.55)",
        "  |> pianoroll()",
        "  .cutoff(300)          filter, in hertz",
        "  .resonance(9)         how much it peaks there",
        "  .lpenv(3.5)           octaves it sweeps up over the note",
        "  .lpdecay(.12)         how fast the sweep falls back",
        "  .adsr(.01,.1,.5,.2)   attack decay sustain release",
        "  .lpf(400) .lpq(9)     the same as cutoff and resonance",
        "  .bank(\"RolandTR808\")  which drum machine — ? lists them",
        "  .speed(2) .velocity(.6) .crush(4) .distort(3)",
        "  .delay(.5) .delaytime(.125) .delayfeedback(.6)",
        "  .room(.6) .roomsize(.9)  the space it is all heard in",
        "",
        "  fast(2) slow(2) rev() palindrome() every(4, &rev/1)",
        "  off(.125, f) jux(&rev/1) superimpose(f) layer([f, g])",
        "  euclid(3, 8) euclid_legato(3, 8) degrade(.3) ply(2)",
        "  segment(8) iter(4) iter_back(4) chunk(4, f) linger(.5)",
        "  zoom(.25, .75) swing(4) ribbon(2, 1) clip(.5) stut(3, .05)",
        "  sometimes(f) often(f) rarely(f) always(f) never(f)",
        "  some_cycles(f) squeeze(p) arp(:up) add(12) mul(2)",
        "  run(4) binary(5) arrange([{2, p}]) polymeter([{3, p}], 4)",
        "  stepcat([a, b]) pace(8) expand(2) take(2) drop(2) zip([a, b])",
        "  shrink() grow() tour(p, [q]) pick(i, [a, b]) invert()",
        "  .fm(3) .fmh(2) .vib(6) .coarse(8) .phaser(2) .vowel(\"a\")",
        "  .ftype(:bandpass) .bpf(900) .orbit(1) .postgain(.5)",
        "  voicing(\"<C^7 Dm7>\")  perlin()",
        "  sine() cosine() saw() isaw() tri() square()",
        "  rand() irand(8) choose([..]) wchoose([{9, :a}]) range(lo, hi)",
        "",
        "  n(\"<0 4 0 9 7>*16\") |> scale(\"g:minor\") |> shape(:saw)",
        "",
        "  scales: " <> Enum.map_join(Enum.take(Scale.names(), 8), " ", &to_string/1),
        "          " <> Enum.map_join(Enum.drop(Scale.names(), 8), " ", &to_string/1),
        "",
        "  ? to close"
      ]
  end

  defp help_rows do
    Enum.map(reference(), fn line -> label(line, style: %{fg: colour_of(line)}) end)
  end

  defp colour_of(""), do: :bright_black
  defp colour_of("  " <> _rest), do: :white
  defp colour_of(_heading), do: :cyan

  @doc """
  One cycle of a slot drawn as columns, with the playhead where `cycle` has reached.

  `█` is a note beginning in that column, `│` the playhead, `·` nothing. A slot that is
  commented out or will not parse draws blank.
  """
  @spec punchcard(map(), float()) :: String.t()
  def punchcard(slot, cycle) do
    filled = slot |> events(cycle) |> Enum.map(&column_of/1) |> MapSet.new()

    for column <- 0..(@steps - 1), into: "" do
      cond do
        column == playhead(cycle) and MapSet.member?(filled, column) -> "▓"
        column == playhead(cycle) -> "│"
        MapSet.member?(filled, column) -> "█"
        true -> "·"
      end
    end
  end

  @doc """
  A slot's cycle as a text pianoroll: `rows` lines, highest pitch first, spanning the range
  the slot's notes cover. `[]` for a slot with no pitched notes.
  """
  @spec pianoroll(map(), float(), pos_integer()) :: [String.t()]
  def pianoroll(slot, cycle, rows \\ 5) do
    pitched = slot |> events(cycle) |> Enum.flat_map(&with_pitch/1)

    case pitched do
      [] ->
        []

      notes ->
        {low, high} = Enum.min_max(Enum.map(notes, &elem(&1, 1)))
        span = max(high - low, 1)

        for row <- (rows - 1)..0//-1 do
          line(notes, row, rows, low, span, cycle)
        end
    end
  end

  defp line(notes, row, rows, low, span, cycle) do
    here =
      notes
      |> Enum.filter(fn {_column, note} -> round((note - low) / span * (rows - 1)) == row end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    for column <- 0..(@steps - 1), into: "" do
      cond do
        MapSet.member?(here, column) -> "█"
        column == playhead(cycle) -> "│"
        true -> " "
      end
    end
  end

  defp with_pitch({column, value}) do
    case Kit.midi(value) do
      nil -> []
      note -> [{column, note}]
    end
  end

  defp playhead(cycle), do: trunc((cycle - Float.floor(cycle)) * @steps)

  defp column_of({column, _value}), do: column

  defp events(slot, cycle), do: View.events(slot, cycle)

  defp playable(%{source: source} = slot), do: if(live?(slot), do: source)
  defp playable(source) when is_binary(source), do: source

  @doc """
  Whether a slot is switched on and has something in it. A slot is off when it is empty or
  starts with one of `off/0`; an off slot is not played, drawn or checked.

      iex> TuningFork.LiveCodeApp.live?(%{source: "_n(\\"0 4\\")"})
      false
  """
  @spec live?(map()) :: boolean()
  defdelegate live?(slot), to: Session

  @doc "The markers that switch a slot off, longest first."
  @spec off() :: [String.t()]
  defdelegate off, to: Session

  @doc "Every switched-on slot stacked into one pattern. Slots that will not parse are left out."
  @spec combined([map()]) :: Pattern.t()
  defdelegate combined(slots), to: Session

  @doc """
  The rows folded into the sources they make, as `{first_row, last_row, source}`. A row
  beginning `|>` carries on the row above it; a continuation with nothing above it is dropped.

      iex> TuningFork.LiveCodeApp.joined([%{source: "s(\\"bd\\")"}, %{source: "|> scope()"}])
      [{0, 1, "s(\\"bd\\") |> scope()"}]
  """
  @spec joined([map()]) :: [{non_neg_integer(), non_neg_integer(), String.t()}]
  defdelegate joined(slots), to: Session

  @doc """
  Whether a row carries on the one above it rather than starting its own.

      iex> TuningFork.LiveCodeApp.continues?(%{source: "  |> scale(\\"g:minor\\")"})
      true
  """
  @spec continues?(map()) :: boolean()
  defdelegate continues?(slot), to: Session

  @doc "The whole source a row belongs to, continuations and all, or `nil` when it plays nothing."
  @spec chain([map()], non_neg_integer()) :: String.t() | nil
  defdelegate chain(slots, index), to: Session

  @doc """
  Parse every slot. Returns the state with `:error` set on the slots that would not parse and
  cleared on the ones that would.
  """
  @spec checked(t()) :: t()
  def checked(state), do: %{state | slots: Session.checked(state.slots)}

  defp evaluate(state, at) do
    state = state |> checked() |> tempo()
    broken = Enum.count(state.slots, & &1.error)

    if playable?(state) do
      state = state |> ensure_stage() |> swap(at)

      %{state | said: said(broken, at)}
    else
      %{state | said: "no audio device — showing the pattern, not playing it"}
    end
  end

  defp said(0, :cycle), do: "evaluated — in at the next cycle"
  defp said(0, :now), do: "evaluated — in now"
  defp said(1, _at), do: "evaluated — one slot would not parse and was left out"
  defp said(broken, _at), do: "evaluated — #{broken} slots would not parse and were left out"

  defp swap(%{stage: nil} = state, _at), do: state

  defp swap(state, at) do
    pattern = combined(state.slots)

    if TuningFork.Stage.cycle(state.stage) == nil do
      TuningFork.Stage.start_pattern(state.stage, pattern, cps: state.cps)
    else
      TuningFork.Stage.update_pattern(state.stage, pattern, at: at)
    end

    state
  end

  defp ensure_stage(%{stage: stage} = state) when is_pid(stage) do
    if Process.alive?(stage), do: state, else: %{state | stage: nil} |> ensure_stage()
  end

  defp ensure_stage(state) do
    case TuningFork.Stage.start_link(name: nil, sink: sink(state), chunk: 256, voices: 48) do
      {:ok, stage} -> %{state | stage: stage}
      {:error, _reason} -> state
    end
  end

  defp start(state) do
    if playable?(state),
      do: state |> checked() |> ensure_stage() |> swap(:now),
      else: checked(state)
  end

  defp sink(%{sink: sink}) when not is_nil(sink), do: sink
  defp sink(_state), do: speaker()

  defp speaker, do: Module.concat([:TuningFork, :Sink, :Speaker])

  @doc """
  Whether this session can produce sound: a `:stage` or `:sink` given to `mount/1`, or a real
  speaker.
  """
  @spec playable?(t()) :: boolean()
  def playable?(%{stage: stage}) when is_pid(stage), do: true
  def playable?(%{sink: sink}) when not is_nil(sink), do: true
  def playable?(_state), do: TuningFork.available?()

  @doc """
  Whether this terminal can draw pixels (kitty, iTerm2 or sixel). `false` when detection
  raises. `pixels: false` in the mount props overrides it.
  """
  @spec pixels?() :: boolean()
  def pixels? do
    FrenchCurve.Capability.detect() in [:kitty, :iterm2, :sixel]
  rescue
    _error -> false
  end

  defp reading(%{stage: stage}) when is_pid(stage) do
    if Process.alive?(stage) do
      {TuningFork.Stage.cycle(stage) || 0.0, TuningFork.Stage.level(stage)}
    else
      {0.0, 0.0}
    end
  end

  defp reading(_state), do: {0.0, 0.0}

  defp toggle(%{playing: true} = state) do
    if state.stage, do: TuningFork.Stage.stop_pattern(state.stage)

    %{state | playing: false, level: 0.0, said: "paused — ctrl+p to play"}
  end

  defp toggle(state) do
    state = state |> ensure_stage() |> swap(:now)

    schedule()

    %{state | playing: true, said: "playing"}
  end

  defp tempo(state) do
    case Session.tempo(state.slots) do
      nil -> state
      cps -> speed(state, cps / 1.0)
    end
  end

  defp speed(state, cps) do
    cps = cps |> max(0.05) |> min(8.0)
    if state.stage, do: TuningFork.Stage.pattern_cps(state.stage, cps)

    %{state | cps: cps, said: "#{:erlang.float_to_binary(cps, decimals: 2)} cycles a second"}
  end

  defp comment(state) do
    source =
      state |> current() |> Map.fetch!(:source) |> String.trim_leading() |> Session.comment()

    state |> put_source(source, String.length(source)) |> evaluate(:cycle)
  end

  defp quit(state) do
    if state.stage && Process.alive?(state.stage), do: GenServer.stop(state.stage, :normal, 2_000)

    {:stop, :normal}
  catch
    :exit, _reason -> {:stop, :normal}
  end

  defp current(state), do: Enum.at(state.slots, state.slot)

  defp put_source(state, source, cursor) do
    slots =
      List.replace_at(state.slots, state.slot, %{source: source, cursor: cursor, error: nil})

    %{state | slots: slots}
  end

  defp put_cursor(state, cursor) do
    slot = current(state)
    bounded = cursor |> max(0) |> min(String.length(slot.source))

    %{state | slots: List.replace_at(state.slots, state.slot, %{slot | cursor: bounded})}
  end

  defp move(state, by), do: put_cursor(state, current(state).cursor + by)

  defp insert(state, text) do
    slot = current(state)
    {before, rest} = String.split_at(slot.source, slot.cursor)

    put_source(state, before <> text <> rest, slot.cursor + 1)
  end

  defp rub_out(state) do
    slot = current(state)

    if slot.cursor == 0 do
      state
    else
      {before, rest} = String.split_at(slot.source, slot.cursor)

      put_source(state, String.slice(before, 0..-2//1) <> rest, slot.cursor - 1)
    end
  end
end
