defmodule TuningFork.Composer.Source do
  @moduledoc """
  A composition written out as formatted `TuningFork.Part` source.

      Source.to_source(project)
      Source.to_source(project, output: :wav)
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Track

  @rate 44_100

  @doc """
  The composition as source, or `""` when no track is audible.

  The result is formatted and depends only on `tuning_fork`. The score is bound to a variable
  named after the project; a name that would not compile as a variable is slugged, and a
  project named `"track"` binds to `song`.

  Options:

    * `:output` — what the last line evaluates to: `:score` (the default) binds the score,
      `:wav` writes `<name>.wav`, `:kino` returns a `Kino.Audio`.
  """
  @spec to_source(Composer.t(), keyword()) :: String.t()
  def to_source(%Composer{} = project, opts \\ []) do
    audible = Enum.filter(project.tracks, &Track.audible?/1)

    if audible == [] do
      ""
    else
      build(project, Enum.zip(audible, names_for(audible)), opts)
    end
  end

  defp build(project, named, opts) do
    name = variable(project.name)

    """
    import TuningFork.Part

    #{aliases(project, named)}

    #{voices(project, named)}

    #{parts(project, named)}

    #{name} = Score.from_parts([#{Enum.map_join(named, ", ", &elem(&1, 1))}], bpm: #{project.bpm}, beats: #{Composer.beats(project)})

    #{tail(project, name, Keyword.get(opts, :output, :score))}\
    """
    |> format()
  end

  defp format(source, passes \\ 3)
  defp format(source, 0), do: IO.iodata_to_binary(source)

  defp format(source, passes) do
    formatted = source |> Code.format_string!() |> IO.iodata_to_binary()

    if formatted == IO.iodata_to_binary(source),
      do: formatted,
      else: format(formatted, passes - 1)
  end

  defp aliases(project, named) do
    kinds = named |> Enum.map(fn {track, _name} -> track.kind end) |> MapSet.new()
    played = MapSet.member?(kinds, :drum) or MapSet.member?(kinds, :pitched)

    used =
      ["Score", "Voice"] ++
        if(played and project.kit == :synth, do: ["Gm"], else: []) ++
        if(played and project.kit != :synth, do: ["Kit"], else: []) ++
        if(MapSet.member?(kinds, :sample), do: ["Sample"], else: [])

    "alias TuningFork.{#{used |> Enum.sort() |> Enum.join(", ")}}"
  end

  defp voices(project, named) do
    base =
      "base = Voice.new(shape: :saw, gain: #{project.gain}, cutoff: 0.45, " <>
        "envelope: TuningFork.Envelope.new(attack: 0.006, sustain: 0.3, release: 0.12))"

    tracks = Enum.map(named, &elem(&1, 0))

    kit =
      if project.kit == :synth and Enum.any?(tracks, &(&1.kind == :drum)),
        do: "\nkit = Gm.drums()",
        else: ""

    instruments =
      tracks
      |> Enum.filter(&(&1.kind == :pitched))
      |> Enum.uniq_by(& &1.sound)
      |> Enum.map_join("\n", &instrument(project, &1))

    recordings =
      named
      |> Enum.filter(fn {track, _name} -> track.kind == :sample end)
      |> Enum.map_join("\n\n", fn {track, name} ->
        """
        #{name}_voice =
          Voice.new(
            sample: Sample.load!(#{inspect(track.path || "")}#{root_option(track)}),
            gain: base.gain,
            cutoff: base.cutoff
          )\
        """
      end)

    [base <> kit, instruments, recordings] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp instrument(%Composer{kit: :synth}, track) do
    "#{track.sound} = Gm.for_program(#{Composer.program_for(track.sound)}, base)"
  end

  defp instrument(project, track) do
    "#{track.sound} = Kit.instrument(#{inspect(Composer.font_for(track.sound))}, 0.5, " <>
      "%{gain: #{project.gain}})"
  end

  defp root_option(%Track{root: root}) when not is_nil(root), do: ", root: :#{root}"
  defp root_option(_none), do: ""

  defp parts(project, named) do
    Enum.map_join(named, "\n\n", fn {track, name} -> part(project, track, name) end)
  end

  defp part(project, %Track{kind: :drum} = track, name) do
    """
    #{name} =
      part(bpm: #{project.bpm}, synth: #{drum(project, track)}, gain: #{track.gain})
      |> repeat(#{project.bars}, fn bar -> steps(bar, "#{pattern(track)}", 1 / #{project.division}) end)\
    """
  end

  defp part(project, track, name) do
    synth = if track.kind == :sample, do: "#{name}_voice", else: track.sound

    """
    #{name} =
      part(bpm: #{project.bpm}, synth: #{synth}, gain: #{track.gain})
      |> repeat(#{project.bars}, fn bar ->
        steps(bar, #{entries(project, track)}, 1 / #{project.division}, release: #{track.ring})
      end)\
    """
  end

  defp drum(%Composer{kit: :synth}, track), do: "kit[#{Composer.drum_note(track.sound)}]"

  defp drum(project, track) do
    "Kit.instrument(#{inspect(Composer.kit_sound(track.sound))}, 0.5, " <>
      "%{bank: #{inspect(project.kit)}, gain: #{project.gain}})"
  end

  defp pattern(%Track{steps: steps}) do
    Enum.map_join(steps, "", fn step ->
      if elem(Track.read(step), 0) > 0, do: "x", else: "."
    end)
  end

  defp entries(project, %Track{steps: steps}) do
    notes = Composer.scale(project)

    inside =
      Enum.map_join(steps, ", ", fn step ->
        case Track.read(step) do
          {0, _length} ->
            "nil"

          {degree, 1} ->
            ":" <> to_string(Enum.at(notes, degree - 1, List.last(notes)))

          {degree, length} ->
            name = ":" <> to_string(Enum.at(notes, degree - 1, List.last(notes)))
            "{#{name}, release: #{length} / #{project.division}}"
        end
      end)

    "[" <> inside <> "]"
  end

  defp tail(_project, name, :score), do: name

  defp tail(project, name, :kino) do
    """
    #{name}
    |> Score.render(#{@rate})#{reverb(project)}
    |> TuningFork.Wav.encode(rate: #{@rate})
    |> Kino.Audio.new(:wav)\
    """
  end

  defp tail(project, name, :wav) do
    """
    #{name}
    |> Score.render(#{@rate})#{reverb(project)}
    |> then(&TuningFork.Wav.write!("#{name}.wav", &1, rate: #{@rate}, channels: 2))\
    """
  end

  defp reverb(%Composer{reverb: room}) when room > 0 do
    "\n|> TuningFork.Fx.reverb(#{@rate}, room: #{room}, mix: 0.2)"
  end

  defp reverb(_none), do: ""

  defp names_for(tracks) do
    tracks
    |> Enum.map(&base_name/1)
    |> Enum.map_reduce(%{}, fn name, seen ->
      case Map.get(seen, name, 0) do
        0 -> {name, Map.put(seen, name, 1)}
        n -> {"#{name}_#{n + 1}", Map.put(seen, name, n + 1)}
      end
    end)
    |> elem(0)
  end

  defp base_name(%Track{kind: :sample} = track) do
    "sample_" <> slug(Path.rootname(Path.basename(track.path || "")))
  end

  defp base_name(%Track{} = track), do: "#{track.kind}_#{slug(track.sound)}"

  defp variable(name) do
    case slug(name) do
      "track" -> "song"
      other -> other
    end
  end

  defp slug(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "track"
      name -> if String.match?(name, ~r/^[a-z]/), do: name, else: "s" <> name
    end
  end
end
