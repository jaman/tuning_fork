defmodule TuningFork.Composer.Arrangement.Flatten do
  @moduledoc """
  Rewrites an arrangement's clips as `:notes` clips wherever their notes can be read, for a
  program that plays notes and nothing else.

      {:ok, notes_only} = Flatten.with_notes(arrangement)

  Steps and patterns become the notes they play. A Strudel clip becomes the events that
  start in its bars, one cycle to a bar: a value with a pitch (`note`, `n` with a `scale`,
  or `freq`) is a note at that pitch, and its `s` is the note's `sound`; a value with only an
  `s` is a hit on that sound. Velocity is the value's `velocity` times its `gain`. Sonic Pi
  loops and recordings have no notes to read and stay as they are.
  """

  alias TuningFork.Composer.Arrangement
  alias TuningFork.Composer.Arrangement.{Clip, Json, Track}
  alias TuningFork.{Kit, Pattern, Strudel}

  @doc """
  The arrangement with every clip it can read as notes rewritten as a `:notes` clip.

  Returns `{:error, message}` for a step, pattern or Strudel chain that does not read.
  """
  @spec with_notes(Arrangement.t()) :: {:ok, Arrangement.t()} | {:error, String.t()}
  def with_notes(%Arrangement{} = arrangement) do
    arrangement.tracks
    |> Enum.reduce_while({:ok, []}, fn track, {:ok, acc} ->
      case track_with_notes(track, arrangement) do
        {:ok, track} -> {:cont, {:ok, [track | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tracks} -> {:ok, %{arrangement | tracks: Enum.reverse(tracks)}}
      error -> error
    end
  end

  defp track_with_notes(%Track{} = track, arrangement) do
    track.clips
    |> Enum.reduce_while({:ok, []}, fn clip, {:ok, acc} ->
      case clip_with_notes(clip, arrangement) do
        {:ok, clip} ->
          {:cont, {:ok, [clip | acc]}}

        {:error, message} ->
          {:halt, {:error, "#{track.name}, the clip at bar #{clip.bar}: #{message}"}}
      end
    end)
    |> case do
      {:ok, clips} -> {:ok, %{track | clips: Enum.reverse(clips)}}
      error -> error
    end
  end

  defp clip_with_notes(%Clip{kind: kind} = clip, arrangement) when kind in [:steps, :pattern] do
    start = Clip.start(clip, arrangement.metre)

    with {:ok, notes} <- Clip.notes(clip, arrangement.metre) do
      {:ok, as_notes(clip, Enum.map(notes, &%{&1 | beat: &1.beat - start}))}
    end
  end

  defp clip_with_notes(%Clip{kind: :strudel} = clip, arrangement) do
    with {:ok, pattern} <- Strudel.pattern(clip.strudel) do
      cycles = clip.beats / arrangement.metre

      notes =
        pattern
        |> Pattern.query({0.0, cycles})
        |> Enum.filter(&starts_within?(&1, cycles))
        |> Enum.map(&event_note(&1, arrangement.metre, clip.beats))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.beat)

      {:ok, as_notes(clip, notes)}
    end
  end

  defp clip_with_notes(%Clip{} = clip, _arrangement), do: {:ok, clip}

  defp as_notes(clip, notes) do
    %Clip{
      kind: :notes,
      bar: clip.bar,
      beat: clip.beat,
      beats: clip.beats,
      notes: notes,
      extra: clip.extra
    }
  end

  defp starts_within?(%{whole: {from, _to}} = event, cycles),
    do: Pattern.onset?(event) and from >= 0.0 and from < cycles

  defp starts_within?(_event, _cycles), do: false

  defp event_note(%{whole: {from, to}, value: value}, metre, beats) do
    beat = from * metre
    sound = sound(value)

    case pitch(value) do
      nil when is_nil(sound) ->
        nil

      pitch ->
        %{
          beat: beat,
          pitch: pitch,
          length: min((to - from) * metre, beats - beat),
          velocity: velocity(value),
          sound: sound
        }
    end
  end

  defp event_note(_event, _metre, _beats), do: nil

  defp sound(%{s: sound}) when is_binary(sound) and sound != "", do: sound
  defp sound(%{sound: sound}) when is_binary(sound) and sound != "", do: sound
  defp sound(_value), do: nil

  defp pitch(%{note: note}) when is_number(note), do: note |> round() |> max(0) |> min(127)

  defp pitch(%{note: note}) when is_binary(note) do
    case Json.pitch(note) do
      {:ok, midi} -> midi
      {:error, _message} -> nil
    end
  end

  defp pitch(%{} = value) when is_map_key(value, :freq) or is_map_key(value, :scale) do
    case Kit.from_map(Map.drop(value, [:s, :sound, :bank]), 0.5, wait: false) do
      nil -> nil
      voice -> (69 + 12 * :math.log2(voice.freq / 440.0)) |> round() |> max(0) |> min(127)
    end
  end

  defp pitch(_value), do: nil

  defp velocity(value) do
    (number(value, :velocity) * number(value, :gain)) |> max(0.0) |> min(1.0)
  end

  defp number(value, key) do
    case Map.get(value, key) do
      number when is_number(number) -> number * 1.0
      _absent -> 1.0
    end
  end
end
