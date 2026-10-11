defmodule TuningFork.Mus do
  @moduledoc """
  Reads DMX MUS, the music format of Doom and its engine's other games, into the same
  `TuningFork.Midi` value a MIDI file reads into, so it plays the same way.

      lump
      |> TuningFork.Mus.parse!()
      |> TuningFork.Gm.score()
      |> TuningFork.Score.render(44_100)

  MUS runs at 140 ticks a second; the result is one track at 140 ticks a beat and sixty
  beats a minute, so its ticks are MUS's own. MUS channel 15, the percussion channel,
  becomes MIDI channel 9 and channels 9 to 14 move up one to make room. A note played
  without a volume takes the channel's last one. Instrument changes become program
  changes; volume, pan, expression and the pedals become their MIDI controllers; system
  events and the end-of-measure marker carry nothing a score uses and are dropped.
  """

  import Bitwise

  alias TuningFork.Midi

  @ticks_per_second 140
  @controllers %{1 => 0, 2 => 1, 3 => 7, 4 => 10, 5 => 11, 6 => 91, 7 => 93, 8 => 64, 9 => 67}

  @doc "Parse a MUS lump: `{:ok, midi}`, or `{:error, :not_mus}` or `{:error, :truncated}`."
  @spec parse(binary()) :: {:ok, Midi.t()} | {:error, :not_mus | :truncated}
  def parse(<<"MUS", 0x1A, length::little-16, start::little-16, _rest::binary>> = lump) do
    if byte_size(lump) < start do
      {:error, :truncated}
    else
      score = binary_part(lump, start, min(length, byte_size(lump) - start))
      events = events(score, 0, %{}, [{0, {:tempo, 1_000_000}}])
      {:ok, %Midi{format: 0, division: @ticks_per_second, tracks: [events]}}
    end
  end

  def parse(_other), do: {:error, :not_mus}

  @doc "Parse a MUS lump, raising `ArgumentError` where `parse/1` would fail."
  @spec parse!(binary()) :: Midi.t()
  def parse!(lump) do
    case parse(lump) do
      {:ok, midi} -> midi
      {:error, reason} -> raise ArgumentError, "could not read that MUS lump: #{inspect(reason)}"
    end
  end

  defp events(<<>>, _tick, _volumes, acc), do: Enum.reverse(acc)

  defp events(<<head, rest::binary>>, tick, volumes, acc) do
    last? = (head &&& 0x80) != 0
    channel = channel(head &&& 0x0F)

    case event(head >>> 4 &&& 7, channel, rest, volumes) do
      :end ->
        Enum.reverse(acc)

      {:truncated} ->
        Enum.reverse(acc)

      {event, rest, volumes} ->
        acc = if event, do: [{tick, event} | acc], else: acc

        if last? do
          {delay, rest} = delay(rest, 0)
          events(rest, tick + delay, volumes, acc)
        else
          events(rest, tick, volumes, acc)
        end
    end
  end

  defp channel(15), do: 9
  defp channel(channel) when channel >= 9, do: channel + 1
  defp channel(channel), do: channel

  defp event(0, channel, <<note, rest::binary>>, volumes),
    do: {{:note_off, channel, note &&& 0x7F, 0}, rest, volumes}

  defp event(1, channel, <<note, rest::binary>>, volumes) do
    if (note &&& 0x80) != 0 do
      case rest do
        <<volume, rest::binary>> ->
          volume = volume &&& 0x7F
          {{:note_on, channel, note &&& 0x7F, volume}, rest, Map.put(volumes, channel, volume)}

        _short ->
          {:truncated}
      end
    else
      {{:note_on, channel, note &&& 0x7F, Map.get(volumes, channel, 127)}, rest, volumes}
    end
  end

  defp event(2, channel, <<bend, rest::binary>>, volumes),
    do: {{:pitch_bend, channel, (bend - 128) / 128}, rest, volumes}

  defp event(3, _channel, <<_system, rest::binary>>, volumes), do: {nil, rest, volumes}

  defp event(4, channel, <<0, value, rest::binary>>, volumes),
    do: {{:program, channel, value &&& 0x7F}, rest, volumes}

  defp event(4, channel, <<controller, value, rest::binary>>, volumes) do
    case Map.get(@controllers, controller) do
      nil -> {nil, rest, volumes}
      number -> {{:control, channel, number, value &&& 0x7F}, rest, volumes}
    end
  end

  defp event(5, _channel, rest, volumes), do: {nil, rest, volumes}
  defp event(6, _channel, _rest, _volumes), do: :end
  defp event(_type, _channel, _rest, _volumes), do: {:truncated}

  defp delay(<<byte, rest::binary>>, acc) do
    acc = (acc <<< 7) + (byte &&& 0x7F)
    if (byte &&& 0x80) != 0, do: delay(rest, acc), else: {acc, rest}
  end

  defp delay(<<>>, acc), do: {acc, <<>>}
end
