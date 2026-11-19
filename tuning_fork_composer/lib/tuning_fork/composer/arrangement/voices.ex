defmodule TuningFork.Composer.Arrangement.Voices do
  @moduledoc """
  The voice each note of an arrangement plays with, chosen from its track's instrument or
  the note's own `sound`.

  Drums and the grid composer's instruments sound as `TuningFork.Composer.voice_for/2`
  makes them, so an arrangement and a grid with the same `:kit` sound alike. A `gm_` name
  is a General MIDI soundfont, synthesised when the kit is `:synth`. `"sample:"` and a path
  plays that recording at each note's pitch. Any other name is a sample bank's.

      Voices.voice(arrangement, track, %{pitch: 62, sound: nil})
  """

  alias TuningFork.Composer
  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.Track
  alias TuningFork.{Gm, Kit, Voice}
  alias TuningFork.Gm.Names
  alias TuningFork.Sample.Bank

  @drums ~w(kick snare hat open_hat tom clap ride crash)

  @drum_names %{
    "bd" => "kick",
    "kick" => "kick",
    "sd" => "snare",
    "sn" => "snare",
    "snare" => "snare",
    "cp" => "clap",
    "clap" => "clap",
    "hh" => "hat",
    "hat" => "hat",
    "oh" => "open_hat",
    "open" => "open_hat",
    "open_hat" => "open_hat",
    "lt" => "tom",
    "mt" => "tom",
    "ht" => "tom",
    "tom" => "tom",
    "rd" => "ride",
    "ride" => "ride",
    "cr" => "crash",
    "crash" => "crash"
  }

  @doc "The drums a track or a note can name."
  @spec drums() :: [String.t()]
  def drums, do: @drums

  @doc """
  The drum a name stands for, as one of `drums/0`, or `nil`.

  Strudel's and the drum machines' short names count: `"bd"` is `"kick"`, `"hh"` is `"hat"`.
  """
  @spec drum(String.t() | nil) :: String.t() | nil
  def drum(name) when is_binary(name), do: Map.get(@drum_names, name)
  def drum(_name), do: nil

  @doc "The MIDI note an instrument plays a note with no pitch at: C2 for a bass, C4 otherwise."
  @spec default_pitch(String.t()) :: 0..127
  def default_pitch("bass"), do: 36
  def default_pitch(_instrument), do: 60

  @doc "Whether `instrument` names something a track can play."
  @spec known?(String.t()) :: boolean()
  def known?("sample:" <> path), do: File.exists?(path)
  def known?("gm_" <> _font = name), do: name in Names.names()

  def known?(name) when is_binary(name) do
    drum(name) != nil or name in pitched_instruments() or Bank.has?(name)
  end

  def known?(_name), do: false

  @doc """
  The voice `note` plays with on `track`, pitched, or `nil` for a sound with no recording.

  A note's `sound` takes the place of the track's instrument for that note.
  """
  @spec voice(Arrangement.t(), Track.t(), map()) :: Voice.t() | nil
  def voice(%Arrangement{} = arrangement, %Track{} = track, note) do
    case source(track, note) do
      {:drum, name} -> arrangement |> drum_voice(name) |> realise(nil)
      {:pitched, name} -> arrangement |> instrument(name) |> realise(pitch(note, name))
    end
  end

  @doc "Whether `note` sounds as a drum on `track`: a drum keeps its own length."
  @spec drum?(Track.t(), map()) :: boolean()
  def drum?(%Track{} = track, note), do: match?({:drum, _name}, source(track, note))

  @doc """
  What `note` sounds as on `track`: `{:drum, name}` with `name` one of `drums/0`, or
  `{:pitched, instrument}`. A note's `sound` takes the place of the track's instrument.
  """
  @spec source(Track.t(), map()) :: {:drum, String.t()} | {:pitched, String.t()}
  def source(%Track{} = track, note) do
    sound = Map.get(note, :sound)

    cond do
      is_binary(sound) and drum(sound) != nil -> {:drum, drum(sound)}
      is_binary(sound) and sound != "" -> {:pitched, sound}
      drum(track.instrument) != nil -> {:drum, drum(track.instrument)}
      true -> {:pitched, track.instrument}
    end
  end

  defp pitch(note, name), do: Map.get(note, :pitch) || default_pitch(name)

  defp drum_voice(arrangement, name) do
    Composer.voice_for(%Composer.Track{kind: :drum, sound: name}, composer(arrangement))
  end

  defp instrument(arrangement, "sample:" <> path) do
    Composer.voice_for(%Composer.Track{kind: :sample, path: path}, composer(arrangement))
  end

  defp instrument(%Arrangement{kit: :synth} = arrangement, "gm_" <> _font = name) do
    Gm.for_program(Names.program(name) || 0, Composer.base_voice(composer(arrangement)))
  end

  defp instrument(arrangement, name) do
    if name in pitched_instruments() do
      Composer.voice_for(%Composer.Track{kind: :pitched, sound: name}, composer(arrangement))
    else
      Kit.instrument(name, 0.5, %{gain: arrangement.gain})
    end
  end

  defp realise(%Voice{} = voice, nil), do: voice
  defp realise(%Voice{} = voice, midi), do: %{voice | freq: frequency(midi)}
  defp realise(instrument, midi) when is_function(instrument, 1), do: instrument.(midi)

  defp frequency(midi), do: 440.0 * :math.pow(2.0, (midi - 69) / 12.0)

  defp composer(%Arrangement{kit: kit, gain: gain}), do: Composer.new(kit: kit, gain: gain)

  defp pitched_instruments, do: Enum.map(Composer.instruments(), &elem(&1, 0))
end
