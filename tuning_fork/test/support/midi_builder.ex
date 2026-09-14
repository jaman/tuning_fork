defmodule TuningFork.MidiBuilder do
  @moduledoc """
  Builds Standard MIDI Files, for testing the reader against.

      MidiBuilder.build([[{0, {:note_on, 0, 60, 100}}, {480, {:note_off, 0, 60, 0}}]])
  """

  import Bitwise

  @doc """
  A file from tracks, each a list of `{delta_ticks, event}`.

  Events are the shapes `TuningFork.Midi` gives back, plus `:end_of_track`, `{:aftertouch,
  channel, note, pressure}`, `{:sysex, data}` and `{:raw, bytes}` for writing a run of events
  that share one status byte. `:end_of_track` is appended to any track that does not finish
  with one.

  ## Options

    * `:format` — the header's format word, default 1 for several tracks and 0 for one
    * `:division` — ticks per beat, default 480
  """
  @spec build([[{non_neg_integer(), term()}]], keyword()) :: binary()
  def build(tracks, opts \\ []) do
    format = Keyword.get(opts, :format, if(length(tracks) > 1, do: 1, else: 0))
    division = Keyword.get(opts, :division, 480)

    header =
      <<"MThd", 6::32, format::16, length(tracks)::16, division::16>>

    Enum.reduce(tracks, header, fn track, acc -> acc <> track(track) end)
  end

  @doc "One `MTrk` chunk from a list of `{delta_ticks, event}`."
  @spec track([{non_neg_integer(), term()}]) :: binary()
  def track(events) do
    body =
      events
      |> ensure_end()
      |> Enum.map(fn {delta, event} -> varint(delta) <> encode(event) end)
      |> IO.iodata_to_binary()

    <<"MTrk", byte_size(body)::32, body::binary>>
  end

  @doc """
  A variable-length quantity, as MIDI writes lengths and delta times.

  Seven bits a byte, most significant first, with the high bit set on all but the last.
  """
  @spec varint(non_neg_integer()) :: binary()
  def varint(value) when value < 128, do: <<value>>

  def varint(value) do
    {leading, [final]} = value |> groups([]) |> Enum.split(-1)

    IO.iodata_to_binary(Enum.map(leading, &<<1::1, &1::7>>) ++ [<<0::1, final::7>>])
  end

  defp groups(0, acc), do: acc
  defp groups(value, acc), do: groups(value >>> 7, [value &&& 0x7F | acc])

  defp ensure_end(events) do
    case List.last(events) do
      {_delta, :end_of_track} -> events
      _other -> events ++ [{0, :end_of_track}]
    end
  end

  defp encode({:note_on, channel, note, velocity}) do
    <<0x90 ||| channel, note, velocity>>
  end

  defp encode({:note_off, channel, note, velocity}) do
    <<0x80 ||| channel, note, velocity>>
  end

  defp encode({:program, channel, program}), do: <<0xC0 ||| channel, program>>

  defp encode({:control, channel, controller, value}) do
    <<0xB0 ||| channel, controller, value>>
  end

  defp encode({:pitch_bend, channel, raw}) do
    value = raw + 8_192

    <<0xE0 ||| channel, value &&& 0x7F, value >>> 7>>
  end

  defp encode({:tempo, microseconds}) do
    <<0xFF, 0x51, 3, microseconds::24>>
  end

  defp encode({:track_name, name}) do
    <<0xFF, 0x03, byte_size(name)>> <> name
  end

  defp encode({:aftertouch, channel, note, pressure}) do
    <<0xA0 ||| channel, note, pressure>>
  end

  defp encode({:sysex, data}) do
    <<0xF0>> <> varint(byte_size(data)) <> data
  end

  defp encode({:raw, bytes}), do: bytes

  defp encode(:end_of_track), do: <<0xFF, 0x2F, 0>>
end
