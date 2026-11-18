defmodule Mix.Tasks.TuningFork.Bake do
  @shortdoc "Bake a composition into a song bundle"

  @moduledoc """
  Render a composition to a song bundle: `mix.wav`, a WAV per stem, `score.mid` and
  `song.json`, in one directory a game reads with `tuning_fork` alone.

      mix tuning_fork.bake song.json
      mix tuning_fork.bake song.json --out priv/music/night --rate 48000
      mix tuning_fork.bake song.json --id night --title "Night Harbour"

  The input is the JSON `TuningFork.Composer.Json.to_map/1` writes. Every file and the
  manifest are written into the output directory, which defaults to the project's name
  beside it.

  ## Options

    * `--out PATH` — the bundle's directory. Defaults to the project's name beside the input
    * `--id NAME` — the bundle's name, default the project's `:name`
    * `--title TEXT` — what the song is called, default the project's `:name`
    * `--section NAME` — the section's name, default `"song"`
    * `--rate N` — samples per second, default 44100. Bake at the game's rate, not yours
    * `--channels N` — 1 or 2, default 2
    * `--playable NAMES` — the stems a game gives to the player, comma-separated; the rest
      becomes `backing.wav`
    * `--quiet` — say nothing unless something is wrong
  """

  use Mix.Task

  alias TuningFork.Composer

  @switches [
    out: :string,
    id: :string,
    title: :string,
    section: :string,
    rate: :integer,
    channels: :integer,
    playable: :string,
    quiet: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, argv} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    case argv do
      [path | _rest] -> bake(path, opts)
      [] -> Mix.raise("which project? mix tuning_fork.bake song.json")
    end
  end

  defp bake(path, opts) do
    project = read(path)
    out = Keyword.get(opts, :out) || Path.join(Path.dirname(path), project.name)

    case Composer.Bake.bake(project, out, bake_options(opts)) do
      {:ok, song} ->
        unless opts[:quiet], do: Mix.shell().info(summary(song, out))
        :ok

      {:error, reason} ->
        Mix.raise("cannot bake #{path}: #{inspect(reason)}")
    end
  end

  defp bake_options(opts) do
    opts = Keyword.take(opts, [:rate, :channels, :id, :title, :section, :playable])

    case Keyword.fetch(opts, :playable) do
      {:ok, names} ->
        playable = names |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        Keyword.put(opts, :playable, playable)

      :error ->
        opts
    end
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- JSON.decode(body),
         true <- is_map(decoded) do
      Composer.Json.from_map(decoded)
    else
      {:error, reason} -> Mix.raise("cannot read #{path}: #{inspect(reason)}")
      false -> Mix.raise("#{path} is not a composition")
    end
  end

  defp summary(song, out) do
    seconds = :erlang.float_to_binary(TuningFork.Song.duration(song), decimals: 1)

    "#{song.id}: #{map_size(song.stems)} stems, #{seconds}s at #{song.sample_rate} Hz " <>
      "-> #{out}"
  end
end
