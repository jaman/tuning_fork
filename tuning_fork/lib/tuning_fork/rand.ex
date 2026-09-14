defmodule TuningFork.Rand do
  @moduledoc """
  Repeatable randomness from a generator value that every function returns alongside its
  result.

      {note, rand} = Rand.pick(Rand.new(42), [:a3, :c4, :e4])
  """

  @type t :: %__MODULE__{state: integer()}

  defstruct state: 1

  @modulus 2_147_483_648
  @multiplier 1_103_515_245
  @increment 12_345

  @doc "A generator seeded from any term. The same seed gives the same sequence anywhere."
  @spec new(term()) :: t()
  def new(seed \\ 1), do: %__MODULE__{state: :erlang.phash2(seed, @modulus - 1) + 1}

  @doc "A number from 0.0 up to but not including 1.0, and the next generator."
  @spec next(t()) :: {float(), t()}
  def next(%__MODULE__{state: state}) do
    stepped = step(state)
    {stepped / @modulus, %__MODULE__{state: stepped}}
  end

  @doc "The generator's bare state moved on one step: a whole number from 0 below `modulus/0`."
  @spec step(pos_integer()) :: non_neg_integer()
  def step(state) when is_integer(state), do: rem(state * @multiplier + @increment, @modulus)

  @doc "The modulus of the generator: every state is below it."
  @spec modulus() :: pos_integer()
  def modulus, do: @modulus

  @doc "A number from `low` up to but not including `high`, and the next generator."
  @spec float(t(), number(), number()) :: {float(), t()}
  def float(rand, low, high) do
    {value, rand} = next(rand)
    {low + value * (high - low), rand}
  end

  @doc "A whole number from `low` to `high`, both included, and the next generator."
  @spec int(t(), integer(), integer()) :: {integer(), t()}
  def int(rand, low, high) do
    {value, rand} = next(rand)
    {low + trunc(value * (high - low + 1)), rand}
  end

  @doc "One element of `list`, and the next generator. An empty list gives `nil`."
  @spec pick(t(), [term()]) :: {term(), t()}
  def pick(rand, []), do: {nil, rand}

  def pick(rand, list) do
    {index, rand} = int(rand, 0, length(list) - 1)
    {Enum.at(list, index), rand}
  end

  @doc "True with the given probability, from 0.0 to 1.0, and the next generator."
  @spec chance(t(), float()) :: {boolean(), t()}
  def chance(rand, probability) do
    {value, rand} = next(rand)
    {value < probability, rand}
  end

  @doc "True one time in `n`, and the next generator."
  @spec one_in(t(), pos_integer()) :: {boolean(), t()}
  def one_in(rand, n), do: chance(rand, 1.0 / n)

  @doc "The list in a different order, and the next generator."
  @spec shuffle(t(), [term()]) :: {[term()], t()}
  def shuffle(rand, list) do
    {tagged, rand} =
      Enum.map_reduce(list, rand, fn item, acc ->
        {value, acc} = next(acc)
        {{value, item}, acc}
      end)

    {tagged |> Enum.sort() |> Enum.map(&elem(&1, 1)), rand}
  end

  @doc """
  `count` independent picks from `list`, and the next generator. The result may repeat an
  element.
  """
  @spec take(t(), [term()], non_neg_integer()) :: {[term()], t()}
  def take(rand, list, count) do
    Enum.map_reduce(1..count//1, rand, fn _n, acc -> pick(acc, list) end)
  end
end
