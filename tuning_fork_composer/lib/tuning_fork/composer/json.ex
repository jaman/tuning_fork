defmodule TuningFork.Composer.Json do
  @moduledoc """
  A composition as string-keyed maps of JSON-safe values, and back.

      project |> Json.to_map() |> Json.from_map()
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Track

  @doc """
  A composition as string-keyed maps. Values are numbers, strings, booleans and lists. A step
  held over more than one step is `%{"d" => degree, "n" => length}`; a step one long is the
  bare degree.
  """
  @spec to_map(Composer.t()) :: map()
  def to_map(%Composer{} = project) do
    %{
      "bpm" => project.bpm,
      "bars" => project.bars,
      "meter" => project.meter,
      "division" => project.division,
      "root" => to_string(project.root),
      "scale" => to_string(project.scale),
      "gain" => project.gain,
      "reverb" => project.reverb,
      "kit" => to_string(project.kit),
      "name" => project.name,
      "tracks" => Enum.map(project.tracks, &track_to_map/1)
    }
  end

  defp track_to_map(%Track{} = track) do
    %{
      "kind" => to_string(track.kind),
      "sound" => track.sound,
      "path" => track.path,
      "root" => if(track.root, do: to_string(track.root)),
      "gain" => track.gain,
      "ring" => track.ring,
      "muted" => track.muted,
      "plays" => track.plays,
      "steps" => Enum.map(track.steps, &step_to_json/1)
    }
  end

  defp step_to_json({degree, length}), do: %{"d" => degree, "n" => length}
  defp step_to_json(degree), do: degree

  @doc """
  A composition from plain maps.

  Takes a map with the keys `to_map/1` produces; anything not a map yields `Composer.new/1`.
  Missing keys fall back to the struct's defaults and unrecognisable values are dropped.
  Never raises. Only note names, scale names and track kinds the composer already knows
  become atoms; any other string falls back to the default.
  """
  @spec from_map(map()) :: Composer.t()
  def from_map(attrs) when is_map(attrs) do
    project =
      Composer.new(
        bpm: integer(attrs["bpm"], 96),
        bars: integer(attrs["bars"], 2),
        meter: integer(attrs["meter"], 4),
        division: integer(attrs["division"], 4),
        root: atom(attrs["root"], :a2),
        scale: atom(attrs["scale"], :minor_pentatonic),
        gain: float(attrs["gain"], 0.5),
        reverb: float(attrs["reverb"], 0.0),
        kit: kit(attrs["kit"]),
        name: to_string(attrs["name"] || "song")
      )

    tracks =
      attrs
      |> Map.get("tracks")
      |> List.wrap()
      |> Enum.map(&track_from_map(&1, Composer.steps_per_bar(project)))

    %{project | tracks: tracks}
  end

  def from_map(_not_a_map), do: Composer.new()

  defp track_from_map(attrs, width) when is_map(attrs) do
    Track.new(
      [
        kind: atom(attrs["kind"], :drum),
        sound: attrs["sound"] || "kick",
        path: attrs["path"],
        root: if(attrs["root"] in [nil, ""], do: nil, else: atom(attrs["root"], nil)),
        gain: float(attrs["gain"], 0.8),
        ring: float(attrs["ring"], 2.0),
        muted: attrs["muted"] == true,
        plays: plays(attrs["plays"]),
        steps: attrs |> Map.get("steps") |> List.wrap() |> Enum.map(&step_from_json/1)
      ],
      width
    )
  end

  defp track_from_map(_other, width), do: Track.new([], width)

  defp step_from_json(%{"d" => degree, "n" => length}) do
    Track.write(integer(degree, 0), integer(length, 1))
  end

  defp step_from_json(degree) when is_integer(degree), do: max(degree, 0)
  defp step_from_json(_anything_else), do: 0

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(value, _default) when is_float(value), do: trunc(value)

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp integer(_value, default), do: default

  defp float(value, _default) when is_number(value), do: value * 1.0

  defp float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> default
    end
  end

  defp float(_value, default), do: default

  defp plays(text) when is_binary(text) and text != "", do: text
  defp plays(_all), do: nil

  defp kit(name) when is_binary(name) and name not in ["", "synth"], do: name
  defp kit(_synth), do: :synth

  @known Map.new(
           Composer.scales() ++
             [:drum, :pitched, :sample] ++
             for(
               octave <- 0..8,
               name <- ~w(c cs d ds e f fs g gs a as b),
               do: :"#{name}#{octave}"
             ),
           &{to_string(&1), &1}
         )

  defp atom(value, default) when is_binary(value), do: Map.get(@known, value, default)

  defp atom(value, _default) when is_atom(value) and not is_nil(value), do: value
  defp atom(_value, default), do: default
end
