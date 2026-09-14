defmodule TuningFork.LoopsApp do
  @moduledoc """
  Live coding named loops in a terminal, each an Elixir block evaluated on its own round.

      mix tuning_fork.loops
  """

  use Drafter, runtime: :reducer

  alias TuningFork.{Part, Score, Session, Stage, Store}

  @tick 150
  @pad 1

  @type loop :: %{
          name: String.t(),
          source: String.t(),
          cursor: non_neg_integer(),
          error: String.t() | nil,
          score: Score.t() | nil,
          stopped: boolean()
        }

  @type reading :: %{beat: float(), rounds: non_neg_integer(), pending?: boolean()}

  @type t :: %{
          loops: [loop()],
          loop: non_neg_integer(),
          stage: pid() | nil,
          sink: module() | nil,
          playing: boolean(),
          help: boolean(),
          naming: String.t() | nil,
          reading: %{String.t() => reading()},
          said: String.t()
        }

  @doc """
  The state the editor starts in.

  `props` is a map or a keyword list:

    * `:loops` — a list of `{name, source}` pairs; without one it opens on `demo/0`. A source
      is Elixir text that must evaluate to a `TuningFork.Score` or a `TuningFork.Part`; a bare
      part is wrapped in a score
    * `:stage` — an already-running `TuningFork.Stage`, used as given rather than started here
    * `:sink` — a `TuningFork.Sink` module used when the app starts its own stage, in place of
      checking for a speaker
  """
  @impl true
  @spec mount(map() | keyword()) :: t()
  def mount(props) do
    props = Map.new(props)

    given =
      case Map.get(props, :loops, demo()) do
        [] -> [{"loop1", ""}]
        loops -> loops
      end

    state = %{
      loops: Enum.map(given, &loop/1),
      loop: 0,
      stage: Map.get(props, :stage),
      sink: Map.get(props, :sink),
      playing: true,
      help: false,
      naming: nil,
      reading: %{},
      said: ""
    }

    schedule()

    start(state)
  end

  @doc "The loops a fresh session opens on: a drum loop and a bass loop, both four beats long."
  @spec demo() :: [{String.t(), String.t()}]
  def demo do
    [
      {"drums",
       "part(bpm: 120, synth: Kit.voice(\"bd\", 0.3))\n" <>
         "|> play(:c3, 1) |> play(:c3, 1) |> play(:c3, 1) |> play(:c3, 1)"},
      {"bass",
       "part(bpm: 120, synth: Kit.voice(%{note: \"c2\", shape: :saw}, 0.4))\n" <>
         "|> play(:c2, 2) |> play(:g2, 2)"}
    ]
  end

  defp loop({name, source}) do
    %{
      name: to_string(name),
      source: source,
      cursor: String.length(source),
      error: nil,
      score: nil,
      stopped: false
    }
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick)

  defp start(state) do
    started =
      if playable?(state) do
        0..(length(state.loops) - 1)//1
        |> Enum.reduce(state, fn index, acc -> %{acc | loop: index} |> evaluate(:now) end)
      else
        state
      end

    %{started | loop: 0, said: greeting(playable?(state))}
  end

  defp greeting(true) do
    "ctrl+e evaluates · ctrl+n new loop · f2 names it · tab comments · ctrl+x stops · ? keys"
  end

  defp greeting(false), do: "no audio device — showing the loops, not playing them"

  @doc false
  @impl true
  def update(message, state)

  def update(:tick, %{playing: false} = state), do: state

  def update(:tick, state) do
    schedule()
    %{state | reading: reading(state)}
  end

  def update({:key, :q, [:ctrl]}, state), do: quit(state)

  def update({:key, :enter}, %{naming: naming} = state) when is_binary(naming), do: rename(state)

  def update({:key, :escape}, %{naming: naming} = state) when is_binary(naming) do
    cancel_naming(state)
  end

  def update({:key, :backspace}, %{naming: naming} = state) when is_binary(naming) do
    rub_out_name(state)
  end

  def update({:key, key}, %{naming: naming} = state) when is_binary(naming) and is_atom(key) do
    case Atom.to_string(key) do
      <<_character::utf8>> = text -> type_name(state, text)
      _longer -> state
    end
  end

  def update({:char, codepoint}, %{naming: naming} = state) when is_binary(naming) do
    type_name(state, <<codepoint::utf8>>)
  end

  def update({:mouse, _event}, %{naming: naming} = state) when is_binary(naming), do: state

  def update({:key, :f2}, state), do: start_naming(state)
  def update({:key, :t, [:ctrl]}, state), do: start_naming(state)
  def update({:key, :"?"}, state), do: %{state | help: not state.help}
  def update({:key, :p, [:ctrl]}, state), do: toggle(state)

  def update({:key, :e, [:ctrl]}, state), do: evaluate(state, :round)
  def update({:key, :r, [:ctrl]}, state), do: evaluate(state, :now)
  def update({:key, :enter, [:ctrl]}, state), do: evaluate(state, :round)

  def update({:key, :n, [:ctrl]}, state), do: new_loop(state)
  def update({:key, :x, [:ctrl]}, state), do: stop_named(state)
  def update({:key, :tab}, state), do: comment(state)

  def update({:key, :enter}, state), do: insert(state, "\n")
  def update({:key, :left}, state), do: move(state, -1)
  def update({:key, :right}, state), do: move(state, 1)
  def update({:key, :up}, state), do: vertical_move(state, -1)
  def update({:key, :down}, state), do: vertical_move(state, 1)
  def update({:key, :home}, state), do: home(state)
  def update({:key, :end}, state), do: end_of_line(state)
  def update({:key, :backspace}, state), do: rub_out(state)
  def update({:key, :delete}, state), do: state |> move(1) |> rub_out()

  def update({:mouse, %{type: :mouse_down, x: x, y: y}}, state) do
    case spot(state, x, y) do
      :summary -> toggle(state)
      {index, nil} -> %{state | loop: index}
      {index, cursor} -> %{state | loop: index} |> put_cursor(cursor)
      nil -> state
    end
  end

  def update({:key, key}, state) when is_atom(key) do
    case Atom.to_string(key) do
      <<_character::utf8>> = text -> insert(state, text)
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
        header("Loops"),
        label(status(state), style: %{fg: :cyan}),
        vertical(body(state), flex: 1),
        footer(footer_text(state))
      ],
      padding: @pad
    )
  end

  @doc """
  The line along the bottom: what just happened, or the name being typed while `F2` is open.

      iex> TuningFork.LoopsApp.footer_text(%{naming: "bass", said: "anything"})
      "name ▸ bass▏ · enter keeps it, esc cancels"
  """
  @spec footer_text(t() | map()) :: String.t()
  def footer_text(%{naming: naming}) when is_binary(naming) do
    "name ▸ #{naming}▏ · enter keeps it, esc cancels"
  end

  def footer_text(state), do: state.said

  defp body(%{help: true}), do: help_rows()

  defp body(state) do
    state.loops
    |> Enum.with_index()
    |> Enum.flat_map(fn {loop, index} -> rows(state, loop, index) end)
  end

  @doc "How many rows `render/1` draws above the first loop: the padding, header and summary."
  @spec rows_above() :: non_neg_integer()
  def rows_above, do: 3

  @doc "The row the summary line is drawn on, which is the one that plays and pauses."
  @spec summary_row() :: non_neg_integer()
  def summary_row, do: 2

  defp status(state) do
    icon = if state.playing, do: "▶", else: "❙❙"
    playing = map_size(state.reading)

    "#{icon}  #{length(state.loops)} loops · #{playing} playing#{tempo(state)}"
  end

  defp tempo(state) do
    case current(state).score do
      %Score{bpm: bpm} -> " · #{trunc(bpm)} bpm"
      nil -> ""
    end
  end

  defp rows(state, loop, index) do
    here? = index == state.loop

    source_rows(loop, here?) ++
      [label(indent(loop) <> status_text(state, loop), style: %{fg: :bright_black})] ++
      error_row(loop)
  end

  defp source_rows(loop, here?) do
    loop
    |> source_lines(here?)
    |> Enum.map(&label(&1, style: %{fg: colour(loop, here?)}))
  end

  @doc """
  A loop's source as the lines drawn on screen: the name and marker on the first, the rest
  lined up under where its source begins.

      iex> TuningFork.LoopsApp.source_lines(%{name: "bd", source: "bd", cursor: 0}, false)
      ["bd   bd"]
  """
  @spec source_lines(loop(), boolean()) :: [String.t()]
  def source_lines(loop, here?) do
    lines = String.split(loop.source, "\n")
    lines = if here?, do: with_cursor(lines, position(lines, loop.cursor)), else: lines
    marker = if here?, do: "▸", else: " "

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> "#{loop.name} #{marker} #{line}"
      {line, _row} -> indent(loop) <> line
    end)
  end

  defp with_cursor(lines, {row, column}) do
    List.update_at(lines, row, fn line ->
      {before, after_} = String.split_at(line, column)
      before <> "▏" <> after_
    end)
  end

  @doc """
  The indent of a loop's continuation lines and status line: the name's width plus 3.

      iex> TuningFork.LoopsApp.indent(%{name: "bass"}) |> String.length()
      7
  """
  @spec indent(loop()) :: String.t()
  def indent(loop), do: String.duplicate(" ", String.length(loop.name) + 3)

  defp status_text(state, loop) do
    case Map.get(state.reading, loop.name) do
      %{beat: beat, rounds: rounds, pending?: pending?} -> playing_text(beat, rounds, pending?)
      nil -> idle_text(loop)
    end
  end

  defp playing_text(beat, rounds, pending?) do
    base = "round #{rounds} · beat #{:erlang.float_to_binary(beat, decimals: 2)}"
    if pending?, do: base <> " · waiting", else: base
  end

  defp idle_text(loop) do
    cond do
      not Session.live?(loop) -> "commented out"
      loop.stopped -> "stopped"
      is_nil(loop.score) -> "not yet evaluated"
      true -> "stopped"
    end
  end

  defp colour(loop, true), do: if(loop.error, do: :red, else: :white)
  defp colour(loop, false), do: if(Session.live?(loop), do: :green, else: :bright_black)

  defp error_row(%{error: nil}), do: []
  defp error_row(loop), do: [label(indent(loop) <> loop.error, style: %{fg: :red})]

  @doc """
  Every loop, as `{index, first row, how many rows}`. A loop's rows are its source lines, its
  status line and, when it has one, its error line.
  """
  @spec layout(t()) :: [{non_neg_integer(), non_neg_integer(), pos_integer()}]
  def layout(state) do
    state.loops
    |> Enum.with_index()
    |> Enum.map_reduce(rows_above(), fn {loop, index}, top ->
      height = loop_height(loop)
      {{index, top, height}, top + height}
    end)
    |> elem(0)
  end

  defp loop_height(loop) do
    lines = length(String.split(loop.source, "\n"))
    lines + 1 + if(loop.error, do: 1, else: 0)
  end

  @doc """
  What a click at `x`, `y` landed on: `:summary` for the summary line, `{loop, column}` for a
  click in a loop's source, `{loop, nil}` for a click on its status or error line, and `nil`
  for anywhere else. `x` and `y` are zero-based from the top left.
  """
  @spec spot(t(), non_neg_integer(), non_neg_integer()) ::
          :summary | {non_neg_integer(), non_neg_integer() | nil} | nil
  def spot(state, x, y)

  def spot(%{help: true}, _x, _y), do: nil
  def spot(_state, _x, y) when y == 2, do: :summary

  def spot(state, x, y) do
    Enum.find_value(layout(state), fn {index, top, height} ->
      if y >= top and y < top + height, do: {index, clicked(state, index, x, y - top)}
    end)
  end

  defp clicked(state, index, x, offset) do
    loop = Enum.at(state.loops, index)
    lines = String.split(loop.source, "\n")

    if offset < length(lines) do
      prefix = if offset == 0, do: "#{loop.name}   ", else: indent(loop)
      into = x - @pad - String.length(prefix)
      line = Enum.at(lines, offset)
      column = into |> max(0) |> min(String.length(line))

      offset_of(lines, offset, column)
    end
  end

  @doc """
  Where in `lines` the character at `cursor` falls, as `{row, column}`.

      iex> TuningFork.LoopsApp.position(["ab", "cd"], 3)
      {1, 0}
  """
  @spec position([String.t()], non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def position(lines, cursor) do
    Enum.reduce_while(lines, {0, cursor}, fn line, {row, remaining} ->
      width = String.length(line)

      if remaining <= width do
        {:halt, {row, remaining}}
      else
        {:cont, {row + 1, remaining - width - 1}}
      end
    end)
  end

  @doc """
  The absolute cursor offset for `{row, column}` of `lines`. The inverse of `position/2`.

      iex> TuningFork.LoopsApp.offset_of(["ab", "cd"], 1, 0)
      3
  """
  @spec offset_of([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def offset_of(lines, row, column) do
    lines |> Enum.take(row) |> Enum.reduce(0, &(&2 + String.length(&1) + 1)) |> Kernel.+(column)
  end

  @doc """
  The next auto-name `Ctrl+N` would use: `loop1`, `loop2`, … skipping whichever are taken.

      iex> TuningFork.LoopsApp.next_name([%{name: "loop1"}, %{name: "loop3"}])
      "loop2"
  """
  @spec next_name([loop()]) :: String.t()
  def next_name(loops) do
    used = MapSet.new(loops, & &1.name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&"loop#{&1}")
    |> Enum.find(&(&1 not in used))
  end

  @doc "The source a new loop opens on, from `TuningFork.Part.Source.template/0`."
  @spec template() :: String.t()
  defdelegate template, to: Part.Source

  defp new_loop(state) do
    name = next_name(state.loops)
    fresh = loop({name, template()})

    %{
      state
      | loops: state.loops ++ [fresh],
        loop: length(state.loops),
        said: "new loop #{name} — ctrl+e to hear it, f2 to name it"
    }
  end

  @doc """
  Whether `name` may be given to the loop at `index`: it must be non-blank and held by no
  other loop. A loop keeping its own name is always allowed.

      iex> TuningFork.LoopsApp.free?([%{name: "drums"}, %{name: "bass"}], 1, "drums")
      false
  """
  @spec free?([loop()], non_neg_integer(), String.t()) :: boolean()
  def free?(loops, index, name) do
    trimmed = String.trim(name)

    trimmed != "" and
      loops
      |> Enum.with_index()
      |> Enum.all?(fn {loop, at} -> at == index or loop.name != trimmed end)
  end

  defp start_naming(state), do: %{state | naming: current(state).name, said: ""}

  defp type_name(state, text), do: %{state | naming: state.naming <> text}

  defp rub_out_name(%{naming: ""} = state), do: state
  defp rub_out_name(state), do: %{state | naming: String.slice(state.naming, 0..-2//1)}

  defp cancel_naming(state), do: %{state | naming: nil, said: "kept #{current(state).name}"}

  defp rename(state) do
    loop = current(state)
    wanted = String.trim(state.naming)

    cond do
      wanted == loop.name -> %{state | naming: nil, said: ""}
      not free?(state.loops, state.loop, wanted) -> %{state | naming: nil, said: refusal(wanted)}
      true -> state |> stop(loop) |> put_current(%{loop | name: wanted}) |> named(loop.name)
    end
  end

  defp refusal(""), do: "a loop needs a name"
  defp refusal(wanted), do: "#{wanted} is taken"

  defp named(state, was) do
    loop = current(state)

    state =
      if loop.score && not loop.stopped && Session.live?(loop) do
        maybe_play(state, loop.name, loop.score, :now)
      else
        state
      end

    %{state | naming: nil, said: "#{was} is now #{loop.name}"}
  end

  defp stop_named(state) do
    loop = current(state)

    if state.stage, do: Stage.stop_loop(state.stage, loop.name)

    state
    |> put_current(%{loop | stopped: true})
    |> Map.put(:said, "#{loop.name} stopped")
  end

  defp comment(state) do
    loop = current(state)
    source = Session.comment(loop.source)
    cursor = min(loop.cursor, String.length(source))

    state |> put_current(%{loop | source: source, cursor: cursor}) |> evaluate(:round)
  end

  defp evaluate(state, at) do
    loop = current(state)

    if Session.live?(loop) do
      run(state, loop, at)
    else
      state
      |> put_current(%{loop | stopped: true})
      |> stop(loop)
      |> Map.put(:said, "commented out")
    end
  end

  defp run(state, loop, at) do
    with {:ok, body} <- Part.Source.compile(loop.source),
         {:ok, score} <- Store.as(loop.name, 0, body) do
      state
      |> put_current(%{loop | error: nil, score: score, stopped: false})
      |> maybe_play(loop.name, score, at, body)
      |> Map.put(:said, said(playable?(state), at))
    else
      {:error, reason} ->
        state |> put_current(%{loop | error: reason}) |> Map.put(:said, "would not evaluate")
    end
  end

  defp stop(state, loop) do
    if state.stage, do: Stage.stop_loop(state.stage, loop.name)
    state
  end

  defp said(true, :round), do: "evaluated — in when it comes round"
  defp said(true, :now), do: "evaluated — in now"
  defp said(false, _at), do: "evaluated — no audio device, showing the loop"

  defp maybe_play(state, name, score, at, body \\ nil) do
    if playable?(state), do: state |> ensure_stage() |> swap(name, score, at, body), else: state
  end

  defp swap(%{stage: nil} = state, _name, _score, _at, _body), do: state

  defp swap(state, name, score, at, body) do
    opts = if body, do: [body: body], else: []

    if Map.has_key?(Stage.loops(state.stage), name) do
      Stage.update_loop(state.stage, name, score, [at: at] ++ opts)
    else
      Stage.start_loop(state.stage, name, score, opts)
    end

    state
  end

  @doc """
  The help text `?` shows, as lines: this app's keys, then
  `TuningFork.Part.Source.reference/0`.
  """
  @spec reference() :: [String.t()]
  def reference do
    [
      "Keys",
      "",
      "  ctrl+e         evaluate, in when the loop comes round",
      "  ctrl+r         evaluate now",
      "  ctrl+n         a new loop, auto-named, with a drum part in it to start from",
      "  f2 or ctrl+t   rename the current loop · enter keeps it, esc cancels",
      "  ctrl+x         stop the current loop",
      "  tab            comment the current loop out, or back in",
      "  enter          break the line",
      "  ctrl+p         play and pause everything · or click the summary line",
      "  ctrl+q         quit",
      ""
    ] ++ Part.Source.reference() ++ ["", "  ? to close"]
  end

  defp help_rows do
    Enum.map(reference(), fn line -> label(line, style: %{fg: colour_of(line)}) end)
  end

  defp colour_of(""), do: :bright_black
  defp colour_of("  " <> _rest), do: :white
  defp colour_of(_heading), do: :cyan

  defp toggle(%{playing: true} = state) do
    if state.stage do
      Stage.hush(state.stage)
      Stage.stop_loops(state.stage)
    end

    %{state | playing: false, reading: %{}, said: "paused — ctrl+p to play"}
  end

  defp toggle(state) do
    state = state |> ensure_stage() |> restart()
    schedule()

    %{state | playing: true, said: "playing"}
  end

  defp restart(%{stage: nil} = state), do: state

  defp restart(state) do
    state.loops
    |> Enum.filter(&(&1.score && not &1.stopped && Session.live?(&1)))
    |> Enum.each(&Stage.start_loop(state.stage, &1.name, &1.score))

    state
  end

  defp quit(state) do
    if state.stage && Process.alive?(state.stage), do: GenServer.stop(state.stage, :normal, 2_000)

    {:stop, :normal}
  catch
    :exit, _reason -> {:stop, :normal}
  end

  defp reading(%{stage: stage}) when is_pid(stage) do
    if Process.alive?(stage), do: Stage.loops(stage), else: %{}
  end

  defp reading(_state), do: %{}

  defp ensure_stage(%{stage: stage} = state) when is_pid(stage) do
    if Process.alive?(stage), do: state, else: %{state | stage: nil} |> ensure_stage()
  end

  defp ensure_stage(state) do
    case Stage.start_link(name: nil, sink: sink(state), voices: 48) do
      {:ok, stage} -> %{state | stage: stage}
      {:error, _reason} -> state
    end
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

  defp current(state), do: Enum.at(state.loops, state.loop)

  defp put_current(state, loop),
    do: %{state | loops: List.replace_at(state.loops, state.loop, loop)}

  defp put_cursor(state, cursor) do
    loop = current(state)
    bounded = cursor |> max(0) |> min(String.length(loop.source))

    put_current(state, %{loop | cursor: bounded})
  end

  defp move(state, by), do: put_cursor(state, current(state).cursor + by)

  defp home(state) do
    loop = current(state)
    lines = String.split(loop.source, "\n")
    {row, _column} = position(lines, loop.cursor)

    put_cursor(state, offset_of(lines, row, 0))
  end

  defp end_of_line(state) do
    loop = current(state)
    lines = String.split(loop.source, "\n")
    {row, _column} = position(lines, loop.cursor)

    put_cursor(state, offset_of(lines, row, String.length(Enum.at(lines, row))))
  end

  defp vertical_move(state, delta) do
    loop = current(state)
    lines = String.split(loop.source, "\n")
    {row, column} = position(lines, loop.cursor)
    target = row + delta

    if target < 0 or target >= length(lines) do
      state
    else
      width = lines |> Enum.at(target) |> String.length()
      put_cursor(state, offset_of(lines, target, min(column, width)))
    end
  end

  defp insert(state, text) do
    loop = current(state)
    {before, rest} = String.split_at(loop.source, loop.cursor)

    put_current(state, %{
      loop
      | source: before <> text <> rest,
        cursor: loop.cursor + String.length(text)
    })
  end

  defp rub_out(state) do
    loop = current(state)

    if loop.cursor == 0 do
      state
    else
      {before, rest} = String.split_at(loop.source, loop.cursor)

      put_current(state, %{
        loop
        | source: String.slice(before, 0..-2//1) <> rest,
          cursor: loop.cursor - 1
      })
    end
  end
end
