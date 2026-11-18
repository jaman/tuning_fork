defmodule TuningFork.Composer.Song do
  @moduledoc """
  A composer project as a `TuningFork.Song`: one section, a stem per audible track.

  The song is what a bake writes and what a game later reads; this module only describes it.
  `TuningFork.Composer.Bake` renders the audio and hands the files to the manifest.

      project |> TuningFork.Composer.Song.to_song() |> TuningFork.Song.write(dir)
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Track
  alias TuningFork.Song

  @rate 44_100
  @channels 2

  @doc """
  The project as a song.

  ## Options

    * `:id` — the bundle's name, default the project's `:name`
    * `:title` — what the song is called, default the project's `:name`
    * `:section` — the section's name, default `"song"`
    * `:playable` — the stems a game gives to the player, by name, default `[]`
    * `:rate` — samples per second, default 44100
    * `:channels` — 1 or 2, default 2
  """
  @spec to_song(Composer.t(), keyword()) :: Song.t()
  def to_song(%Composer{} = project, opts \\ []) do
    {sections, seconds} = sections(project, Keyword.get(opts, :section))

    Song.new(
      id: Keyword.get(opts, :id, project.name),
      title: Keyword.get(opts, :title, project.name),
      bpm: project.bpm,
      time_signature: {project.meter, 4},
      key: key(project),
      sample_rate: Keyword.get(opts, :rate, @rate),
      channels: Keyword.get(opts, :channels, @channels),
      duration_s: seconds,
      sections: sections,
      stems: stems_of(project),
      playable: Keyword.get(opts, :playable, []),
      mix: "mix.wav",
      score: "score.mid"
    )
  end

  @doc """
  The audible tracks of `project`, as `{name, index, track}`.

  A muted or empty track is in neither the mix nor the stems, so it is left out. A name is
  the track's sound — `"kick"`, `"bass"` — with its position appended when two tracks share
  one, so every stem has a name of its own. `index` is its position in `:tracks`, which is
  what a section names.
  """
  @spec stems(Composer.t()) :: [{String.t(), non_neg_integer(), Track.t()}]
  def stems(%Composer{} = project) do
    audible =
      project.tracks
      |> Enum.with_index()
      |> Enum.filter(fn {track, _index} -> Track.audible?(track) end)

    counts = Enum.frequencies(Enum.map(audible, fn {track, _index} -> base_name(track) end))

    Enum.map(audible, fn {track, index} ->
      base = base_name(track)
      {if(counts[base] > 1, do: "#{base}-#{index}", else: base), index, track}
    end)
  end

  @doc "How long one pass of the grid runs, in seconds."
  @spec duration(Composer.t()) :: float()
  def duration(%Composer{} = project), do: Composer.beats(project) * 60.0 / project.bpm

  defp stems_of(project) do
    Map.new(stems(project), fn {name, _index, track} ->
      {name, %{"file" => "stems/#{name}.wav", "gain" => track.gain, "muted" => false}}
    end)
  end

  # Each section starts where the one before it ended, so a game cues by name and time.
  defp sections(project, first_name) do
    project
    |> Composer.sections()
    |> Enum.with_index()
    |> Enum.map_reduce(0.0, fn {section, index}, at ->
      name = if index == 0 and is_binary(first_name), do: first_name, else: section.name
      stop = at + section.bars * project.meter * 60.0 / project.bpm
      {%{name: name, start_s: at, end_s: stop}, stop}
    end)
  end

  defp key(%Composer{root: root, scale: scale}) do
    %{"tonic" => tonic(root), "mode" => Atom.to_string(scale)}
  end

  defp tonic(nil), do: nil

  defp tonic(root) do
    root
    |> Atom.to_string()
    |> String.replace(~r/\d+$/, "")
    |> String.upcase()
  end

  defp base_name(%Track{kind: :sample, path: path}) when is_binary(path) and path != "" do
    path |> Path.basename() |> Path.rootname()
  end

  defp base_name(%Track{sound: sound}) when is_binary(sound) and sound != "", do: sound
  defp base_name(%Track{kind: kind}), do: Atom.to_string(kind)
end
