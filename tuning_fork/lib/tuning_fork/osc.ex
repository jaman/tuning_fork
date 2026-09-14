defmodule TuningFork.Osc do
  @moduledoc """
  Open Sound Control messages, as the bytes that go over the wire.

      iex> TuningFork.Osc.encode("/play", [60, 0.8])
      <<"/play", 0, 0, 0, ",if", 0, 0, 0, 0, 60, 63, 76, 204, 205>>
  """

  @immediately 1

  @seventy_years 2_208_988_800

  @doc """
  A message as bytes.

  Each argument is an integer (`i`), float (`f`), binary (`s`), `{:blob, bytes}` (`b`),
  `true`, `false` or `nil` (`T`, `F`, `N`), `{:int64, n}` (`h`) or `{:double, f}` (`d`).

      iex> TuningFork.Osc.encode("/hush", [])
      <<"/hush", 0, 0, 0, ",", 0, 0, 0>>
  """
  @spec encode(String.t(), [term()]) :: binary()
  def encode(address, args \\ []) when is_binary(address) and is_list(args) do
    tags = Enum.map_join(args, &tag/1)

    padded(address) <> padded("," <> tags) <> IO.iodata_to_binary(Enum.map(args, &argument/1))
  end

  @doc """
  Several messages under one time tag.

      iex> bundle = TuningFork.Osc.bundle([{"/a", [1]}, {"/b", [2]}])
      iex> <<"#bundle", 0, _rest::binary>> = bundle

  `at` is `:now` (immediately), a `DateTime`, or a two-element `{seconds, fraction}` NTP tag.
  """
  @spec bundle([{String.t(), [term()]}], :now | DateTime.t() | {integer(), integer()}) :: binary()
  def bundle(messages, at \\ :now) do
    body =
      messages
      |> Enum.map(fn {address, args} -> encode(address, args) end)
      |> Enum.map(&(<<byte_size(&1)::big-32>> <> &1))
      |> IO.iodata_to_binary()

    padded("#bundle") <> timetag(at) <> body
  end

  @doc """
  The address and arguments a message carries.

      iex> TuningFork.Osc.decode(TuningFork.Osc.encode("/play", [60, "bd", true]))
      {:ok, "/play", [60, "bd", true]}

  `{:error, :not_a_message}` for anything that is not a message this understands.
  """
  @spec decode(binary()) :: {:ok, String.t(), [term()]} | {:error, atom()}
  def decode(binary) when is_binary(binary) do
    with {address, rest} <- read_string(binary),
         {<<",", tags::binary>>, args} <- read_string(rest) do
      {:ok, address, arguments(tags, args, [])}
    else
      _otherwise -> {:error, :not_a_message}
    end
  rescue
    _error -> {:error, :not_a_message}
  end

  defp arguments(<<>>, _rest, acc), do: Enum.reverse(acc)

  defp arguments(<<tag, tags::binary>>, rest, acc) do
    {value, left} = argument_of(tag, rest)

    arguments(tags, left, [value | acc])
  end

  defp argument_of(?i, <<value::big-signed-32, rest::binary>>), do: {value, rest}
  defp argument_of(?f, <<value::big-float-32, rest::binary>>), do: {value, rest}
  defp argument_of(?h, <<value::big-signed-64, rest::binary>>), do: {{:int64, value}, rest}
  defp argument_of(?d, <<value::big-float-64, rest::binary>>), do: {{:double, value}, rest}
  defp argument_of(?T, rest), do: {true, rest}
  defp argument_of(?F, rest), do: {false, rest}
  defp argument_of(?N, rest), do: {nil, rest}
  defp argument_of(?s, rest), do: read_string(rest)

  defp argument_of(?b, <<size::big-32, rest::binary>>) do
    <<blob::binary-size(size), left::binary>> = rest
    over = rem(4 - rem(size, 4), 4)
    <<_padding::binary-size(over), after_padding::binary>> = left

    {{:blob, blob}, after_padding}
  end

  defp read_string(binary) do
    [text, _rest] = :binary.split(binary, <<0>>)

    {text, skip(binary, byte_size(text) + 1)}
  end

  defp skip(binary, used) do
    over = rem(used, 4)
    from = if over == 0, do: used, else: used + (4 - over)

    binary_part(binary, from, byte_size(binary) - from)
  end

  defp padded(text) do
    with_null = text <> <<0>>
    over = rem(byte_size(with_null), 4)

    if over == 0, do: with_null, else: with_null <> :binary.copy(<<0>>, 4 - over)
  end

  defp tag(value) when is_integer(value), do: "i"
  defp tag(value) when is_float(value), do: "f"
  defp tag(value) when is_binary(value), do: "s"
  defp tag(true), do: "T"
  defp tag(false), do: "F"
  defp tag(nil), do: "N"
  defp tag({:blob, _bytes}), do: "b"
  defp tag({:int64, _value}), do: "h"
  defp tag({:double, _value}), do: "d"

  defp argument(value) when is_integer(value), do: <<value::big-signed-32>>
  defp argument(value) when is_float(value), do: <<value::big-float-32>>
  defp argument(value) when is_binary(value), do: padded(value)
  defp argument(value) when value in [true, false, nil], do: <<>>
  defp argument({:int64, value}), do: <<value::big-signed-64>>
  defp argument({:double, value}), do: <<value::big-float-64>>

  defp argument({:blob, bytes}) do
    over = rem(byte_size(bytes), 4)
    tail = if over == 0, do: <<>>, else: :binary.copy(<<0>>, 4 - over)

    <<byte_size(bytes)::big-32>> <> bytes <> tail
  end

  defp timetag(:now), do: <<0::big-32, @immediately::big-32>>
  defp timetag({seconds, fraction}), do: <<seconds::big-32, fraction::big-32>>

  defp timetag(%DateTime{} = at) do
    <<DateTime.to_unix(at) + @seventy_years::big-32, 0::big-32>>
  end
end
