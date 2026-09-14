defmodule TuningFork.Midi.Message do
  @moduledoc """
  MIDI messages, as the bytes that go down the wire.

      iex> TuningFork.Midi.Message.note_on(60, 100)
      <<0x90, 60, 100>>
      iex> TuningFork.Midi.Message.note_on(60, 100, channel: 3)
      <<0x92, 60, 100>>
  """

  import Bitwise

  @type channel :: 1..16

  @typedoc """
  A message read back from the wire. Channels are 1 to 16; a bend runs from -1.0 to 1.0.
  """
  @type event ::
          {:note_on, channel(), 0..127, 1..127}
          | {:note_off, channel(), 0..127, 0..127}
          | {:control, channel(), 0..127, 0..127}
          | {:program, channel(), 0..127}
          | {:bend, channel(), float()}
          | {:aftertouch, channel(), 0..127}
          | {:poly_aftertouch, channel(), 0..127, 0..127}
          | :clock
          | :start
          | :continue
          | :stop

  @doc """
  Read the message at the front of `bytes` as `{:ok, event}`; `parse_all/1` reads every
  message in a binary. A note on at velocity 0 is a note off, as the wire means it.
  `{:error, :short}` for fewer bytes than the message needs, `{:error, :unknown}` for a
  status this does not read.

      iex> TuningFork.Midi.Message.parse(<<0x92, 60, 100>>)
      {:ok, {:note_on, 3, 60, 100}}
  """
  @spec parse(binary()) :: {:ok, event()} | {:error, :short | :unknown}
  def parse(bytes) when is_binary(bytes) do
    case take(bytes) do
      {:ok, event, _rest} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every message in `bytes`, in order, skipping any it does not read.

      iex> TuningFork.Midi.Message.parse_all(<<0x90, 60, 100, 0xF8>>)
      [{:note_on, 1, 60, 100}, :clock]
  """
  @spec parse_all(binary()) :: [event()]
  def parse_all(bytes) when is_binary(bytes), do: parse_all(bytes, [])

  defp parse_all(<<>>, acc), do: Enum.reverse(acc)

  defp parse_all(bytes, acc) do
    case take(bytes) do
      {:ok, event, rest} -> parse_all(rest, [event | acc])
      {:error, _reason} -> parse_all(binary_part(bytes, 1, byte_size(bytes) - 1), acc)
    end
  end

  defp take(<<0x8::4, ch::4, note, velocity, rest::binary>>),
    do: {:ok, {:note_off, ch + 1, note, velocity}, rest}

  defp take(<<0x9::4, ch::4, note, 0, rest::binary>>),
    do: {:ok, {:note_off, ch + 1, note, 0}, rest}

  defp take(<<0x9::4, ch::4, note, velocity, rest::binary>>),
    do: {:ok, {:note_on, ch + 1, note, velocity}, rest}

  defp take(<<0xA::4, ch::4, note, value, rest::binary>>),
    do: {:ok, {:poly_aftertouch, ch + 1, note, value}, rest}

  defp take(<<0xB::4, ch::4, controller, value, rest::binary>>),
    do: {:ok, {:control, ch + 1, controller, value}, rest}

  defp take(<<0xC::4, ch::4, number, rest::binary>>), do: {:ok, {:program, ch + 1, number}, rest}
  defp take(<<0xD::4, ch::4, value, rest::binary>>), do: {:ok, {:aftertouch, ch + 1, value}, rest}

  defp take(<<0xE::4, ch::4, low, high, rest::binary>>) do
    {:ok, {:bend, ch + 1, ((high <<< 7) + low) / 8_191.5 - 1.0}, rest}
  end

  defp take(<<0xF8, rest::binary>>), do: {:ok, :clock, rest}
  defp take(<<0xFA, rest::binary>>), do: {:ok, :start, rest}
  defp take(<<0xFB, rest::binary>>), do: {:ok, :continue, rest}
  defp take(<<0xFC, rest::binary>>), do: {:ok, :stop, rest}

  defp take(<<status, _rest::binary>>) when status >= 0x80 and status < 0xF0,
    do: {:error, :short}

  defp take(<<>>), do: {:error, :short}
  defp take(_other), do: {:error, :unknown}

  @doc """
  Start a note. `note` and `velocity` are clamped to 0..127; `:channel` is 1 to 16, default 1.

      iex> TuningFork.Midi.Message.note_on(64, 127, channel: 16)
      <<0x9F, 64, 127>>
  """
  @spec note_on(integer(), integer(), keyword()) :: binary()
  def note_on(note, velocity, opts \\ []) do
    <<0x90 ||| wire(opts), seven(note), seven(velocity)>>
  end

  @doc """
  Stop a note. `note` and `velocity` are clamped to 0..127; `:channel` is 1 to 16, default 1.

      iex> TuningFork.Midi.Message.note_off(64)
      <<0x80, 64, 0>>
  """
  @spec note_off(integer(), integer(), keyword()) :: binary()
  def note_off(note, velocity \\ 0, opts \\ []) do
    <<0x80 ||| wire(opts), seven(note), seven(velocity)>>
  end

  @doc """
  Set a controller. `controller` and `value` are clamped to 0..127; `:channel` is 1 to 16.

      iex> TuningFork.Midi.Message.control(7, 90)
      <<0xB0, 7, 90>>
  """
  @spec control(integer(), integer(), keyword()) :: binary()
  def control(controller, value, opts \\ []) do
    <<0xB0 ||| wire(opts), seven(controller), seven(value)>>
  end

  @doc """
  Choose a program. `number` is clamped to 0..127; `:channel` is 1 to 16, default 1.

      iex> TuningFork.Midi.Message.program(33)
      <<0xC0, 33>>
  """
  @spec program(integer(), keyword()) :: binary()
  def program(number, opts \\ []), do: <<0xC0 ||| wire(opts), seven(number)>>

  @doc """
  Bend, from `-1.0` down to `1.0` up. `0.0` is centre.

      iex> TuningFork.Midi.Message.bend(0.0)
      <<0xE0, 0, 64>>
  """
  @spec bend(float(), keyword()) :: binary()
  def bend(amount, opts \\ []) do
    value = round((clamp(amount, -1.0, 1.0) + 1.0) * 8_191.5)

    <<0xE0 ||| wire(opts), value &&& 0x7F, value >>> 7 &&& 0x7F>>
  end

  @doc "Silence a channel: every note off, all sound off, and the sustain pedal up."
  @spec hush(keyword()) :: binary()
  def hush(opts \\ []) do
    control(64, 0, opts) <> control(123, 0, opts) <> control(120, 0, opts)
  end

  @doc """
  A velocity from a gain of `0.0` to `1.0`. A gain outside that range is clamped.

      iex> TuningFork.Midi.Message.velocity(1.0)
      127
      iex> TuningFork.Midi.Message.velocity(0.5)
      64
  """
  @spec velocity(number()) :: 0..127
  def velocity(gain), do: seven(round(clamp(gain, 0.0, 1.0) * 127))

  defp wire(opts) do
    case Keyword.get(opts, :channel, 1) do
      channel when channel in 1..16 -> channel - 1
      _other -> 0
    end
  end

  defp seven(value) when is_integer(value), do: value |> max(0) |> min(127)

  defp clamp(value, low, high), do: value |> max(low) |> min(high)
end
