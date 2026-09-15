defmodule TuningFork.ComposerApp do
  @moduledoc """
  A step sequencer in a terminal, drawn with Drafter over `TuningFork.Composer`.

      mix tuning_fork.compose
  """

  use Drafter, runtime: :reducer

  alias TuningFork.Composer
  alias TuningFork.Composer.{Source, Track}

  @empty "·"
  @hit "█"
  @held "▬"

  @typedoc """
  The editor's state, threaded through `mount/1`, `update/2` and `render/1`.

    * `:project` — the composition being edited
    * `:track` — the row the cursor is on, zero-based
    * `:step` — the column the cursor is on, zero-based
    * `:dragging` — true while a drag is lengthening a note
    * `:playing` — the `TuningFork.Stage` playing the bed, or `nil`
    * `:rendered` — the last render and the project it was made from, or `nil`
    * `:sink` — the `TuningFork.Sink` `p` plays through, or `nil` for the speaker
    * `:out` — the path `w` writes to
    * `:said` — the message line under the grid
  """
  @type t :: %{
          project: Composer.t(),
          track: non_neg_integer(),
          step: non_neg_integer(),
          dragging: boolean(),
          playing: pid() | nil,
          rendered: {Composer.t(), binary()} | nil,
          sink: module() | nil,
          out: Path.t(),
          said: String.t()
        }

  @doc """
  The state the editor starts in.

  `props` is a map or a keyword list, either of which may carry:

    * `:project` — a `TuningFork.Composer` to open on, default `Composer.demo/0`
    * `:out` — where `w` writes the generated source, default `"song.exs"`
    * `:sink` — a `TuningFork.Sink` module `p` plays through, in place of checking for a
      speaker

  Any other key is ignored.
  """
  @spec mount(map() | keyword()) :: t()
  def mount(props) do
    props = Map.new(props)

    %{
      project: Map.get(props, :project) || Composer.demo(),
      track: 0,
      step: 0,
      dragging: false,
      playing: nil,
      rendered: nil,
      sink: Map.get(props, :sink),
      out: Map.get(props, :out, "song.exs"),
      said:
        "click or drag · arrows and space · +/- pitch · </> length · p play/stop · w write · q quit"
    }
  end

  @doc false
  def render(state) do
    project = state.project

    vertical(
      [
        header("Compose"),
        label(settings_line(state), style: %{fg: :cyan}),
        label(ruler(project), style: %{fg: :bright_black}),
        vertical(rows(state), flex: 1),
        label(""),
        label(state.said, style: %{fg: :bright_black}),
        footer(
          bindings: [
            {"click", "place"},
            {"drag", "length"},
            {"+/-", "pitch"},
            {"</>", "length"},
            {"m", "mute"},
            {"a/x", "track"},
            {"p", "play/stop"},
            {"w", "write"},
            {"q", "quit"}
          ]
        )
      ],
      gap: 0
    )
  end

  defp settings_line(state) do
    project = state.project
    playing = if state.playing, do: " · ▶ playing", else: ""

    "#{project.bpm} bpm · #{project.bars} bars · #{project.meter}/#{project.division} · " <>
      "#{project.root} #{project.scale} · gain #{project.gain}#{playing}"
  end

  defp ruler(project) do
    marks =
      Enum.map_join(0..(Composer.steps_per_bar(project) - 1)//1, "", fn step ->
        if rem(step, project.division) == 0 do
          beat = step |> div(project.division) |> Kernel.+(1) |> to_string()
          " " <> String.slice(beat, -1..-1) <> " "
        else
          "   "
        end
      end)

    String.duplicate(" ", label_width()) <> marks
  end

  defp rows(%{project: %Composer{tracks: []}}) do
    [label("  no tracks — press a to add one", style: %{fg: :bright_black})]
  end

  defp rows(state) do
    state.project.tracks
    |> Enum.with_index()
    |> Enum.map(fn {track, index} -> row(track, index, state) end)
  end

  defp row(track, index, state) do
    here? = index == state.track
    cursor = if here?, do: state.step, else: -1

    style =
      cond do
        track.muted -> %{fg: :bright_black}
        here? -> %{fg: :white, bold: true}
        true -> %{fg: :bright_white}
      end

    label(name_cell(track, index, state) <> steps_cell(track, cursor), style: style)
  end

  defp name_cell(track, index, state) do
    marker = if index == state.track, do: "▸", else: " "
    muted = if track.muted, do: "-", else: " "
    name = track.sound || Path.basename(track.path || "sample")

    "#{marker}#{muted}#{String.pad_trailing(String.slice(name, 0, 9), 9)} "
  end

  defp label_width, do: 12
  defp cell_width, do: 3

  @doc """
  How many rows `render/1` draws above the first track. Any line added above the grid in
  `render/1` must be counted here.
  """
  @spec rows_above() :: non_neg_integer()
  def rows_above, do: 3

  @doc """
  The track and step at a point on screen, or `nil` for anywhere else.

  `x` and `y` are zero-based, counted from the top left of the screen.
  """
  @spec hit(t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def hit(state, x, y) do
    track = y - rows_above()
    step = div(x - label_width(), cell_width())

    within? =
      x >= label_width() and
        track >= 0 and track < Composer.track_count(state.project) and
        step >= 0 and step < Composer.steps_per_bar(state.project)

    if within?, do: {track, step}
  end

  defp steps_cell(track, cursor) do
    held = Track.held(track)

    track.steps
    |> Enum.with_index()
    |> Enum.map_join("", fn {step, index} ->
      {degree, _length} = Track.read(step)

      glyph =
        cond do
          degree > 0 and track.kind == :drum -> @hit
          degree > 0 -> to_string(degree)
          Enum.at(held, index) -> @held
          true -> @empty
        end

      if index == cursor, do: "[" <> glyph <> "]", else: " " <> glyph <> " "
    end)
  end

  @doc """
  The next state after a message, or `{:stop, :normal}` to quit.

  `message` is a Drafter event: `{:key, atom}` with the character as an atom, or
  `{:mouse, %{type: type, x: x, y: y}}` where `type` is `:mouse_down`, `:mouse_up`, `:move`
  or `:scroll` (a `:scroll` also carries `:direction`). `x` and `y` are zero-based from the
  top left. Notes are placed on `:mouse_down`, not `:mouse_up`. A message the editor has no use
  for returns `state` unchanged; this never raises on an unknown one.

  `{:key, :q}` stops whatever is playing and returns `{:stop, :normal}`; every other message
  returns a state.
  """
  @spec update(term(), t()) :: t() | {:stop, :normal}
  def update({:key, :q}, state) do
    stop_playing(state)
    {:stop, :normal}
  end

  def update({:key, key}, state) when key in [:left, :right, :up, :down] do
    move(state, key)
  end

  def update({:key, :space}, state) do
    edit(state, &Composer.toggle_step(&1, state.track, state.step))
  end

  def update({:key, key}, state) when key in [:+, :=] do
    edit(state, &Composer.cycle_step(&1, state.track, state.step, 1))
  end

  def update({:key, key}, state) when key in [:-, :_] do
    edit(state, &Composer.cycle_step(&1, state.track, state.step, -1))
  end

  def update({:key, key}, state) when key in [:>, :.] do
    edit(state, &Composer.grow(&1, state.track, state.step, 1))
  end

  def update({:key, key}, state) when key in [:<, :","] do
    edit(state, &Composer.grow(&1, state.track, state.step, -1))
  end

  def update({:key, :m}, state) do
    edit(state, &Composer.toggle_mute(&1, state.track))
  end

  def update({:key, :a}, state) do
    project = Composer.add_track(state.project, kind: :drum, sound: "kick")

    %{state | project: project, track: Composer.track_count(project) - 1, step: 0}
  end

  def update({:key, :x}, state) do
    project = Composer.remove_track(state.project, state.track)

    %{
      state
      | project: project,
        track: min(state.track, max(Composer.track_count(project) - 1, 0))
    }
  end

  def update({:key, :c}, state) do
    edit(state, &Composer.clear_track(&1, state.track))
  end

  def update({:key, :k}, state) do
    edit(state, &Composer.update_track(&1, state.track, kind: next_kind(current(state))))
  end

  def update({:key, :i}, state) do
    edit(state, &Composer.update_track(&1, state.track, sound: next_sound(current(state))))
  end

  def update({:key, :p}, state), do: play(state)
  def update({:key, :w}, state), do: write(state)

  def update({:mouse, %{type: :mouse_down, x: x, y: y}}, state) do
    case hit(state, x, y) do
      nil ->
        state

      {track, step} ->
        at = %{state | track: track, step: step, dragging: true}

        if pitched?(at) do
          edit(at, &Composer.cycle_step(&1, track, step, 1))
        else
          edit(at, &Composer.toggle_step(&1, track, step))
        end
    end
  end

  def update({:mouse, %{type: :move, x: x, y: y}}, %{dragging: true} = state) do
    case hit(state, x, y) do
      {track, step} when track == state.track and step > state.step ->
        edit(state, &Composer.set_length(&1, track, state.step, step - state.step + 1))

      _elsewhere ->
        state
    end
  end

  def update({:mouse, %{type: :mouse_up}}, state), do: %{state | dragging: false}

  def update({:mouse, %{type: :scroll, direction: direction, x: x, y: y}}, state) do
    case hit(state, x, y) do
      nil ->
        state

      {track, step} ->
        by = if direction in [:up, :scroll_up], do: 1, else: -1

        %{state | track: track, step: step}
        |> edit(&Composer.cycle_step(&1, track, step, by))
    end
  end

  def update(_anything_else, state), do: state

  defp pitched?(state), do: current(state).kind != :drum

  defp current(state), do: Composer.track(state.project, state.track) || %Track{}

  defp next_kind(%Track{kind: kind}) do
    order = [:drum, :pitched, :sample]

    case Enum.find_index(order, &(&1 == kind)) do
      nil -> hd(order)
      at -> Enum.at(order, rem(at + 1, length(order)))
    end
  end

  defp next_sound(%Track{kind: :drum, sound: sound}), do: cycle(Composer.drums(), sound)
  defp next_sound(%Track{kind: :pitched, sound: sound}), do: cycle(Composer.instruments(), sound)
  defp next_sound(%Track{sound: sound}), do: sound

  defp cycle(list, current) do
    ids = Enum.map(list, &elem(&1, 0))
    at = Enum.find_index(ids, &(&1 == current)) || -1

    Enum.at(ids, rem(at + 1, length(ids)))
  end

  defp move(state, :left), do: %{state | step: max(state.step - 1, 0)}

  defp move(state, :right) do
    %{state | step: min(state.step + 1, Composer.steps_per_bar(state.project) - 1)}
  end

  defp move(state, :up), do: %{state | track: max(state.track - 1, 0)}

  defp move(state, :down) do
    %{state | track: min(state.track + 1, max(Composer.track_count(state.project) - 1, 0))}
  end

  defp edit(state, change), do: %{state | project: change.(state.project)}

  defp sink(%{sink: sink}) when not is_nil(sink), do: sink

  defp sink(_state) do
    speaker = Module.concat([:TuningFork, :Sink, :Speaker])
    if Code.ensure_loaded?(speaker) and TuningFork.available?(), do: speaker
  end

  defp play(%{playing: stage} = state) when is_pid(stage) do
    stop_playing(state) |> Map.put(:said, "stopped")
  end

  defp play(state) do
    cond do
      Composer.track_count(state.project) == 0 ->
        %{state | said: "nothing to play yet"}

      sink(state) == nil ->
        %{state | said: "no audio device — w writes the source instead"}

      true ->
        {pcm, state} = rendered(state)

        {:ok, stage} =
          TuningFork.Stage.start_link(name: nil, sink: sink(state), chunk: 256, voices: 32)

        TuningFork.Stage.bed(stage, pcm)

        %{
          state
          | playing: stage,
            said: "playing #{Float.round(TuningFork.Wav.duration(pcm), 1)}s — p to stop"
        }
    end
  end

  @doc """
  The composition as PCM, with the state to carry forward.

  Called again with an unchanged project it returns the kept bytes without rendering; called
  after any edit it renders afresh.
  """
  @spec rendered(t()) :: {binary(), t()}
  def rendered(%{rendered: {project, pcm}, project: project} = state), do: {pcm, state}

  def rendered(state) do
    pcm = state.project |> Composer.to_score() |> TuningFork.Score.render(44_100)

    {pcm, %{state | rendered: {state.project, pcm}}}
  end

  @doc """
  Stop whatever is playing and forget it. Safe to call when nothing is.

  A live stage is stopped with `GenServer.stop/3` and killed if it has not stopped within
  2 seconds. Never raises; the returned state has `:playing` set to `nil`.
  """
  @spec stop_playing(t()) :: t()
  def stop_playing(%{playing: stage} = state) when is_pid(stage) do
    if Process.alive?(stage) do
      try do
        GenServer.stop(stage, :normal, 2_000)
      catch
        :exit, _reason -> Process.exit(stage, :kill)
      end
    end

    %{state | playing: nil}
  end

  def stop_playing(state), do: %{state | playing: nil}

  @doc false
  def handle_info(_message, state), do: {:noreply, state}

  defp write(state) do
    case Source.to_source(state.project, output: :wav) do
      "" ->
        %{state | said: "nothing to write — every track is empty or muted"}

      source ->
        File.write!(state.out, source)
        %{state | said: "wrote #{state.out} — mix run #{state.out}"}
    end
  end
end
