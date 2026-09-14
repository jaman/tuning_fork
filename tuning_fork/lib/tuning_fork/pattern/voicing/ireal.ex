defmodule TuningFork.Pattern.Voicing.Ireal do
  @moduledoc "The `ireal` and `ireal-ext` chord voicing dictionaries: chord symbol to voicings as interval names."

  @simple %{
    "" => [
      "1P 5P 8P 10M",
      "1P 5P 8P 10M 12P",
      "3M 5P 8P 10M 12P",
      "3M 8P 10M 12P 15P",
      "5P 8P 10M 12P 15P"
    ],
    "+" => [
      "1P 3M 6m 8P 10M",
      "1P 6m 8P 10M 13m",
      "3M 6m 8P 10M 13m",
      "3M 8P 10M 13m 15P",
      "6m 8P 10M 13m 15P",
      "6m 10M 13m 15P 17M"
    ],
    "-" => ["1P 3m 5P 8P 10m", "1P 5P 8P 10m 12P", "3m 5P 8P 10m 12P", "5P 8P 10m 12P 15P"],
    "-#5" => ["1P 6m 8P 10m 13m", "3m 6m 8P 10m 13m", "6m 8P 10m 13m 15P"],
    "-11" => [
      "1P 3m 7m 9M 11P",
      "3m 7m 8P 9M 11P",
      "1P 4P 7m 10m 12P",
      "5P 8P 11P 14m",
      "3m 7m 9M 11P 15P",
      "5P 8P 11P 14m 16M",
      "7m 10m 12P 15P 18P"
    ],
    "-6" => [
      "1P 3m 5P 6M 8P",
      "1P 5P 6M 8P 10m",
      "3m 5P 6M 8P 10m",
      "1P 5P 8P 10m 13M",
      "3m 5P 8P 10m 13M",
      "5P 8P 10m 12P 13M",
      "5P 8P 10m 13M 15P"
    ],
    "-69" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "3m 6M 9M 10m 12P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 9M 10m 13M",
      "5P 8P 10m 13M 16M"
    ],
    "-7" => [
      "1P 3m 5P 7m 10m",
      "1P 5P 7m 10m 12P",
      "3m 7m 8P 10m 12P",
      "3m 7m 8P 10m 14m",
      "5P 7m 8P 10m 14m",
      "7m 10m 12P 14m 15P",
      "5P 8P 10m 14m 17m",
      "7m 10m 12P 15P 17m"
    ],
    "-7b5" => [
      "3m 5d 7m 8P 10m",
      "1P 7m 10m 12d",
      "1P 5d 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 7m 8P 10m 14m",
      "5d 8P 10m 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "-9" => [
      "1P 3m 5P 7m 9M",
      "3m 5P 7m 8P 9M",
      "3m 7m 8P 9M 12P",
      "5P 8P 9M 10m 14m",
      "3m 7m 9M 12P 15P",
      "7m 10m 12P 15P 16M"
    ],
    "-M7" => [
      "1P 3m 5P 7M 10m",
      "1P 5P 7M 10m 12P",
      "3m 7M 8P 10m 12P",
      "5P 7M 8P 10m 14M",
      "5P 8P 10m 14M 17m"
    ],
    "-M9" => ["1P 3m 5P 7M 9M", "1P 7M 9M 10m 12P", "3m 7M 8P 9M 12P", "5P 8P 9M 10m 14M"],
    "-^7" => [
      "1P 3m 5P 7M 10m",
      "1P 5P 7M 10m 12P",
      "3m 7M 8P 10m 12P",
      "5P 7M 8P 10m 14M",
      "5P 8P 10m 14M 17m"
    ],
    "-^9" => ["1P 3m 5P 7M 9M", "1P 7M 9M 10m 12P", "3m 7M 8P 9M 12P", "5P 8P 9M 10m 14M"],
    "-add9" => ["1P 2M 3m 5P 8P", "1P 3m 5P 9M", "3m 5P 8P 9M 12P", "5P 8P 9M 10m 12P"],
    "-b6" => [
      "1P 5P 6m 8P 10m",
      "1P 5P 8P 10m 13m",
      "3m 5P 8P 10m 13m",
      "5P 8P 10m 13m",
      "5P 8P 10m 13m 15P"
    ],
    "11" => ["1P 5P 7m 9M 11P", "5P 7m 8P 9M 11P", "7m 8P 9M 11P 12P", "7m 8P 11P 12P 16M"],
    "13" => [
      "1P 6M 7m 9M 10M",
      "1P 7m 9M 10M 13M",
      "3M 7m 8P 9M 13M",
      "7m 8P 9M 10M 13M",
      "7m 9M 10M 13M 15P"
    ],
    "13#11" => ["1P 6M 7m 10M 12d", "3M 7m 9M 12d 13M", "7m 10M 12d 13M 16M"],
    "13#9" => ["1P 3M 6M 7m 10m", "3M 7m 8P 10m 13M", "7m 10M 13M 14m 17m"],
    "13b9" => [
      "1P 3M 6M 7m 9m",
      "1P 6M 7m 9m 10M",
      "3M 7m 9m 10M 13M",
      "3M 7m 10M 13M 16m",
      "7m 10M 13M 16m 17M"
    ],
    "13sus" => ["1P 4P 6M 7m 9M", "1P 7m 9M 11P 13M", "5P 7m 9M 11P 13M", "7m 9M 11P 13M 15P"],
    "2" => ["1P 5P 8P 9M", "1P 5P 8P 9M 12P", "5P 8P 9M 12P"],
    "5" => ["1P 5P 8P 12P", "5P 8P 12P 15P"],
    "6" => ["1P 5P 6M 8P 10M", "1P 5P 8P 10M 13M", "3M 5P 8P 10M 13M", "5P 8P 10M 12P 13M"],
    "69" => ["1P 5P 6M 9M 10M", "1P 5P 9M 10M 13M", "3M 5P 8P 9M 13M", "5P 8P 9M 10M 13M"],
    "7" => [
      "1P 5P 7m 8P 10M",
      "1P 7m 8P 10M 12P",
      "3M 7m 8P 10M 12P",
      "3M 7m 8P 10M 14m",
      "3M 7m 10M 12P 15P",
      "7m 10M 12P 14m 15P",
      "7m 10M 12P 15P 17M"
    ],
    "7#11" => ["1P 3M 7m 10M 12d", "3M 7m 8P 10M 12d", "7m 10M 12d 14m 15P"],
    "7#5" => ["1P 3M 7m 10M 13m", "3M 7m 8P 10M 13m", "3M 7m 8P 13m 14m", "7m 10M 13m 14m 15P"],
    "7#9" => ["1P 3M 7m 10m", "3M 7m 8P 10m 14m", "7m 10m 10M 14m 15P"],
    "7#9#11" => ["1P 3M 7m 10m 12d", "3M 7m 10m 12d 15P", "7m 10M 12d 15P 17m"],
    "7#9#5" => ["1P 3M 7m 10m 13m", "3M 7m 10m 13m 15P", "7m 10M 13m 15P 17m"],
    "7#9b5" => ["1P 3M 7m 10m 12d", "3M 7m 10m 12d 15P", "7m 10M 12d 15P 17m"],
    "7alt" => [
      "3M 7m 8P 9m 12d",
      "1P 7m 10m 10M 13m",
      "3M 7m 8P 10m 13m",
      "3M 7m 9m 12d 15P",
      "3M 7m 10m 13m 15P",
      "7m 10M 12d 15P 17m",
      "7m 10M 13m 15P 17m"
    ],
    "7b13" => ["1P 3M 7m 10M 13m", "3M 7m 8P 10M 13m", "3M 7m 8P 13m 14m", "7m 10M 13m 14m 15P"],
    "7b13sus" => ["1P 5P 7m 11P 13m", "5P 7m 8P 11P 13m", "7m 11P 13m 14m 15P"],
    "7b5" => ["1P 3M 7m 10M 12d", "3M 7m 8P 10M 12d", "7m 10M 12d 14m 15P"],
    "7b9" => ["1P 3M 7m 9m 10M", "3M 7m 8P 9m 10M", "3M 7m 8P 9m 14m", "7m 9m 10M 14m 15P"],
    "7b9#11" => ["1P 7m 9m 10M 12d", "3M 7m 8P 9m 12d", "7m 8P 10M 12d 16m"],
    "7b9#5" => ["1P 7m 9m 10M 13m", "3M 7m 8P 9m 13m", "7m 9m 10M 13m 15P"],
    "7b9#9" => ["1P 3M 7m 9m 10m", "3M 7m 8P 9m 10m", "7m 8P 10M 16m 17m"],
    "7b9b13" => ["1P 7m 9m 10M 13m", "3M 7m 8P 9m 13m", "7m 9m 10M 13m 15P"],
    "7b9b5" => ["1P 7m 9m 10M 12d", "3M 7m 8P 9m 12d", "7m 8P 10M 12d 16m"],
    "7b9sus" => ["1P 5P 7m 9m 11P", "5P 7m 8P 9m 11P", "7m 8P 11P 14m 16m"],
    "7sus" => ["1P 5P 7m 8P 11P", "5P 8P 11P 12P 14m", "7m 8P 11P 12P 14m", "7m 11P 12P 14m 18P"],
    "7susadd3" => ["1P 4P 5P 7m 10M", "5P 8P 10M 11P 14m", "7m 11P 12P 15P 17M"],
    "9" => [
      "1P 5P 7m 9M 10M",
      "1P 7m 9M 10M 12P",
      "3M 7m 8P 9M 12P",
      "7m 9M 10M 14m 15P",
      "3M 7m 8P 12P 16M",
      "7m 10M 12P 15P 16M"
    ],
    "9#11" => ["1P 7m 9M 10M 12d", "3M 7m 8P 9M 12d", "7m 10M 12d 15P 16M"],
    "9#5" => [
      "1P 7m 9M 10M 13m",
      "3M 7m 9M 10M 13m",
      "3M 7m 9M 13m 14m",
      "7m 10M 13m 14m 16M",
      "7m 10M 13m 16M 17M"
    ],
    "9b5" => ["1P 7m 9M 10M 12d", "3M 7m 8P 9M 12d", "7m 10M 12d 15P 16M"],
    "9sus" => ["1P 5P 7m 9M 11P", "5P 7m 8P 9M 11P", "7m 8P 9M 11P 12P", "7m 8P 11P 12P 16M"],
    "M" => [
      "1P 5P 8P 10M",
      "1P 5P 8P 10M 12P",
      "3M 5P 8P 10M 12P",
      "3M 8P 10M 12P 15P",
      "5P 8P 10M 12P 15P"
    ],
    "M13" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 8P 13M 16M",
      "7M 8P 10M 13M 16M"
    ],
    "M7" => [
      "1P 5P 7M 10M 12P",
      "1P 10M 12P 14M",
      "3M 8P 10M 12P 14M",
      "5P 8P 10M 12P 14M",
      "5P 8P 10M 14M 17M"
    ],
    "M7#11" => [
      "1P 5P 7M 10M 12d",
      "3M 7M 8P 10M 12d",
      "1P 7M 10M 12d 14M",
      "3M 7M 8P 12d 14M",
      "5P 8P 10M 12d 14M"
    ],
    "M7#5" => ["1P 6m 7M 10M 13m", "3M 7M 8P 10M 13m", "6m 7M 8P 10M 13m"],
    "M9" => [
      "1P 5P 7M 9M 10M",
      "1P 7M 9M 10M 12P",
      "3M 7M 8P 9M 12P",
      "3M 7M 8P 12P 16M",
      "5P 8P 10M 14M 16M",
      "7M 8P 10M 12P 16M"
    ],
    "M9#11" => ["1P 3M 5d 7M 9M", "1P 7M 9M 10M 12d", "3M 7M 8P 9M 12d", "3M 8P 9M 12d 14M"],
    "^" => [
      "1P 5P 8P 10M",
      "1P 5P 8P 10M 12P",
      "3M 5P 8P 10M 12P",
      "3M 8P 10M 12P 15P",
      "5P 8P 10M 12P 15P"
    ],
    "^13" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 8P 13M 16M",
      "7M 8P 10M 13M 16M"
    ],
    "^7" => [
      "1P 5P 7M 10M 12P",
      "1P 10M 12P 14M",
      "3M 8P 10M 12P 14M",
      "5P 8P 10M 12P 14M",
      "5P 8P 10M 14M 17M"
    ],
    "^7#11" => [
      "1P 5P 7M 10M 12d",
      "3M 7M 8P 10M 12d",
      "1P 7M 10M 12d 14M",
      "3M 7M 8P 12d 14M",
      "5P 8P 10M 12d 14M"
    ],
    "^7#5" => ["1P 6m 7M 10M 13m", "3M 7M 8P 10M 13m", "6m 7M 8P 10M 13m"],
    "^9" => [
      "1P 5P 7M 9M 10M",
      "1P 7M 9M 10M 12P",
      "3M 7M 8P 9M 12P",
      "3M 7M 8P 12P 16M",
      "5P 8P 10M 14M 16M",
      "7M 8P 10M 12P 16M"
    ],
    "^9#11" => ["1P 3M 5d 7M 9M", "1P 7M 9M 10M 12d", "3M 7M 8P 9M 12d", "3M 8P 9M 12d 14M"],
    "add9" => [
      "1P 5P 8P 9M 10M",
      "1P 5P 9M 10M 12P",
      "3M 8P 9M 10M 12P",
      "3M 8P 9M 12P 15P",
      "5P 8P 9M 12P 17M"
    ],
    "aug" => [
      "1P 3M 6m 8P 10M",
      "1P 6m 8P 10M 13m",
      "3M 6m 8P 10M 13m",
      "3M 8P 10M 13m 15P",
      "6m 8P 10M 13m 15P",
      "6m 10M 13m 15P 17M"
    ],
    "h" => [
      "3m 5d 7m 8P 10m",
      "1P 5d 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 7m 8P 10m 14m",
      "5d 8P 10m 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "h7" => [
      "3m 5d 7m 8P 10m",
      "1P 5d 7m 10m 12d",
      "1P 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 7m 8P 10m 14m",
      "5d 8P 10m 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "h9" => ["1P 7m 9M 10m 12d", "3m 7m 8P 9M 12d", "5d 8P 9M 10m 14m", "7m 10m 12d 15P 16M"],
    "m" => ["1P 3m 5P 8P 10m", "1P 5P 8P 10m 12P", "3m 5P 8P 10m 12P", "5P 8P 10m 12P 15P"],
    "m#5" => ["1P 6m 8P 10m 13m", "3m 6m 8P 10m 13m", "6m 8P 10m 13m 15P"],
    "m11" => [
      "1P 3m 7m 9M 11P",
      "3m 7m 8P 9M 11P",
      "1P 4P 7m 10m 12P",
      "5P 8P 11P 14m",
      "3m 7m 9M 11P 15P",
      "5P 8P 11P 14m 16M",
      "7m 10m 12P 15P 18P"
    ],
    "m6" => [
      "1P 3m 5P 6M 8P",
      "1P 5P 6M 8P 10m",
      "3m 5P 6M 8P 10m",
      "1P 5P 8P 10m 13M",
      "3m 5P 8P 10m 13M",
      "5P 8P 10m 12P 13M",
      "5P 8P 10m 13M 15P"
    ],
    "m69" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "3m 6M 9M 10m 12P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 9M 10m 13M",
      "5P 8P 10m 13M 16M"
    ],
    "m7" => [
      "1P 3m 5P 7m 10m",
      "1P 5P 7m 10m 12P",
      "3m 7m 8P 10m 12P",
      "3m 7m 8P 10m 14m",
      "5P 7m 8P 10m 14m",
      "7m 10m 12P 14m 15P",
      "5P 8P 10m 14m 17m",
      "7m 10m 12P 15P 17m"
    ],
    "m7b5" => [
      "3m 5d 7m 8P 10m",
      "1P 7m 10m 12d",
      "1P 5d 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 7m 8P 10m 14m",
      "5d 8P 10m 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "m9" => [
      "1P 3m 5P 7m 9M",
      "3m 5P 7m 8P 9M",
      "3m 7m 8P 9M 12P",
      "5P 8P 9M 10m 14m",
      "3m 7m 9M 12P 15P",
      "7m 10m 12P 15P 16M"
    ],
    "m^7" => [
      "1P 3m 5P 7M 10m",
      "1P 5P 7M 10m 12P",
      "3m 7M 8P 10m 12P",
      "5P 7M 8P 10m 14M",
      "5P 8P 10m 14M 17m"
    ],
    "m^9" => ["1P 3m 5P 7M 9M", "1P 7M 9M 10m 12P", "3m 7M 8P 9M 12P", "5P 8P 9M 10m 14M"],
    "madd9" => ["1P 2M 3m 5P 8P", "1P 3m 5P 9M", "3m 5P 8P 9M 12P", "5P 8P 9M 10m 12P"],
    "mb6" => [
      "1P 5P 6m 8P 10m",
      "1P 5P 8P 10m 13m",
      "3m 5P 8P 10m 13m",
      "5P 8P 10m 13m",
      "5P 8P 10m 13m 15P"
    ],
    "o" => ["1P 5d 8P 10m 12d", "3m 8P 10m 12d 15P", "5d 8P 10m 12d 15P"],
    "o7" => [
      "1P 6M 8P 10m 12d",
      "1P 6M 10m 12d 13M",
      "3m 8P 10m 12d 13M",
      "3m 8P 12d 13M 15P",
      "5d 10m 12d 13M 15P",
      "5d 10m 13M 15P 17m",
      "6M 12d 13M 15P 17m",
      "6M 12d 15P 17m 19d"
    ],
    "sus" => ["1P 4P 5P 8P", "1P 4P 5P 8P 11P", "5P 8P 11P 12P", "5P 8P 11P 12P 15P"]
  }

  @complex %{
    "" => [
      "1P 3M 5P 6M 9M",
      "1P 5P 8P 10M 12P",
      "3M 5P 9M 10M 12P",
      "1P 5P 8P 10M 13M",
      "3M 8P 10M 13M 15P",
      "5P 9M 10M 12P 15P"
    ],
    "+" => [
      "1P 6m 8P 9M 10M",
      "1P 6m 8P 10M 13m",
      "3M 8P 9M 10M 13m",
      "3M 8P 10M 13m 15P",
      "6m 10M 13m 15P 16M",
      "6m 10M 13m 15P 17M"
    ],
    "-" => [
      "1P 3m 5P 8P 10m",
      "1P 3m 5P 9M 11P",
      "3m 5P 8P 9M 11P",
      "5P 8P 9M 10m 11P",
      "1P 5P 9M 10m 12P",
      "3m 5P 8P 10m 12P",
      "5P 8P 10m 12P 15P"
    ],
    "-#5" => ["1P 6m 8P 10m 13m", "3m 6m 8P 11P 13m", "6m 8P 10m 13m 15P"],
    "-11" => [
      "3m 5P 7m 9M 11P",
      "7m 9M 10m 11P",
      "1P 4P 7m 10m 12P",
      "3m 7m 9M 11P 12P",
      "7m 9M 10m 11P 12P",
      "3m 7m 9M 11P 14m",
      "4P 10m 12P 14m",
      "5P 8P 11P 14m",
      "5P 8P 11P 14m 16M",
      "7m 10m 12P 16M 18P",
      "7m 10m 11P 16M 21m"
    ],
    "-6" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "1P 5P 6M 10m 11P",
      "3m 5P 6M 8P 11P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 10m 11P 13M",
      "5P 8P 10m 13M 16M"
    ],
    "-69" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "3m 6M 9M 10m 12P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 9M 10m 13M",
      "5P 8P 10m 13M 16M"
    ],
    "-7" => [
      "1P 3m 5P 7m 9M",
      "1P 3m 5P 7m 10m",
      "1P 5P 7m 10m 11P",
      "3m 7m 8P 10m 11P",
      "1P 5P 7m 10m 12P",
      "3m 7m 9M 10m 12P",
      "3m 7m 8P 10m 14m",
      "5P 7m 9M 10m 14m",
      "7m 10m 11P 14m 15P",
      "7m 10m 12P 15P 16M",
      "5P 8P 11P 14m 17m",
      "7m 10m 12P 15P 17m"
    ],
    "-7b5" => [
      "1P 5d 7m 10m 11P",
      "3m 5d 7m 8P 11P",
      "5d 7m 8P 10m 11P",
      "1P 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 8P 10m 11P 14m",
      "7m 10m 11P 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "-9" => [
      "1P 3m 5P 7m 9M",
      "1P 3m 7m 9M 11P",
      "3m 7m 9M 10m 11P",
      "3m 7m 9M 10m 12P",
      "3m 7m 9M 10m 14m",
      "3m 7m 9M 12P 15P",
      "7m 10m 11P 14m 16M",
      "7m 10m 12P 16M 18P"
    ],
    "-M7" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "-M9" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "-^7" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "-^9" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "-add9" => ["1P 2M 3m 5P 8P", "1P 3m 5P 9M", "3m 5P 8P 9M 12P", "5P 8P 9M 10m 12P"],
    "-b6" => ["1P 3m 5P 6m 8P", "3m 5P 8P 11P 13m", "5P 8P 10m 11P 13m"],
    "11" => [
      "1P 4P 6M 7m 9M",
      "1P 5P 7m 9M 11P",
      "4P 6M 7m 9M 11P",
      "5P 8P 9M 11P 14m",
      "7m 9M 11P 13M 15P",
      "7m 11P 12P 14m 18P"
    ],
    "13" => [
      "3M 7m 9M 10M 13M",
      "3M 7m 9M 13M 15P",
      "3M 7m 10M 13M 16M",
      "7m 10M 12P 13M 16M",
      "7m 10M 13M 16M 17M",
      "7m 10M 13M 16M 19P"
    ],
    "13#11" => ["3M 7m 9M 12d 13M", "7m 10M 12d 13M 16M"],
    "13#9" => ["3M 7m 10m 10M 13M", "7m 10M 13M 14m 17m"],
    "13b9" => ["3M 7m 9m 10M 13M", "3M 7m 10M 13M 16m", "7m 10M 13M 16m 17M"],
    "13sus" => [
      "1P 4P 6M 7m 9M",
      "1P 7m 9M 11P 13M",
      "4P 7m 9M 11P 13M",
      "7m 9M 11P 13M 15P",
      "7m 11P 13M 14m 16M",
      "7m 11P 13M 16M 18P"
    ],
    "2" => ["1P 5P 6M 8P 9M", "1P 5P 8P 9M 12P", "5P 8P 9M 12P 13M", "5P 8P 9M 12P 15P"],
    "5" => ["1P 5P 8P 12P", "1P 5P 8P 9M 12P", "5P 8P 12P 15P", "5P 8P 12P 15P 16M"],
    "6" => [
      "1P 5P 6M 9M 10M",
      "1P 5P 9M 10M 13M",
      "3M 5P 9M 10M 13M",
      "5P 8P 9M 10M 13M",
      "3M 6M 9M 12P 15P"
    ],
    "69" => [
      "1P 5P 6M 9M 10M",
      "1P 5P 9M 10M 13M",
      "3M 5P 9M 10M 13M",
      "5P 8P 9M 10M 13M",
      "3M 6M 9M 12P 15P"
    ],
    "7" => [
      "1P 5P 7m 8P 10M",
      "1P 7m 8P 10M 12P",
      "3M 7m 8P 10M 12P",
      "3M 7m 8P 10M 14m",
      "3M 7m 10M 12P 15P",
      "7m 10M 12P 14m 15P",
      "7m 10M 12P 15P 17M",
      "7m 10M 14m 17M 19P"
    ],
    "7#11" => ["1P 3M 7m 9M 12d", "3M 7m 9M 12d 13M", "7m 10M 12d 13M 16M"],
    "7#5" => [
      "1P 3M 7m 10M 13m",
      "3M 7m 8P 10M 13m",
      "3M 7m 8P 13m 14m",
      "7m 10M 13m 14m 15P",
      "7m 10M 13m 14m 17M"
    ],
    "7#9" => ["1P 3M 7m 10m", "3M 7m 10m 10M 12P", "3M 7m 10m 12P 14m", "7m 10M 12P 14m 17m"],
    "7#9#11" => ["3M 7m 10m 10M 12d", "3M 7m 10m 12d 14m", "7m 10M 12d 14m 17m"],
    "7#9#5" => ["3M 7m 10m 10M 13m", "3M 7m 10m 13m 14m", "7m 10M 13m 14m 17m"],
    "7#9b5" => ["3M 7m 10m 10M 12d", "3M 7m 10m 12d 14m", "7m 10M 12d 14m 17m"],
    "7alt" => [
      "3M 7m 8P 10m 13m",
      "3M 7m 9m 12d 13m",
      "3M 7m 9m 10m 13m",
      "3M 7m 10m 13m 14m",
      "3M 7m 9m 12d 14m",
      "3M 7m 10m 13m 15P",
      "3M 7m 10m 13m 16m",
      "7m 10M 12d 14m 16m",
      "7m 10M 12d 13m 16m",
      "7m 10M 13m 15P 17m",
      "7m 10M 13m 16m 17m",
      "7m 10M 13m 16m 19d"
    ],
    "7b13" => [
      "1P 3M 7m 10M 13m",
      "3M 7m 8P 10M 13m",
      "3M 7m 8P 13m 14m",
      "7m 10M 13m 14m 15P",
      "7m 10M 13m 14m 17M"
    ],
    "7b13sus" => ["1P 5P 7m 11P 13m", "5P 7m 8P 11P 13m", "7m 11P 13m 14m 15P"],
    "7b5" => ["1P 3M 7m 9M 12d", "3M 7m 9M 12d 13M", "7m 10M 12d 13M 16M"],
    "7b9" => ["1P 3M 7m 9m 10M", "3M 7m 8P 9m 10M", "3M 7m 8P 9m 14m", "7m 9m 10M 14m 15P"],
    "7b9#11" => [
      "3M 7m 9m 10M 12d",
      "3M 7m 9m 12d 14m",
      "7m 8P 10M 12d 16m",
      "7m 10M 12d 14m 16m"
    ],
    "7b9#5" => [
      "1P 7m 9m 10M 13m",
      "3M 7m 9m 10M 13m",
      "3M 7m 10M 13m 16m",
      "7m 10M 13m 14m 16m",
      "7m 10M 13m 16m 17M"
    ],
    "7b9#9" => ["1P 3M 7m 9m 10m", "3M 7m 10m 13m 16m", "7m 10M 13m 16m 17m"],
    "7b9b13" => [
      "1P 7m 9m 10M 13m",
      "3M 7m 9m 10M 13m",
      "3M 7m 10M 13m 16m",
      "7m 10M 13m 14m 16m",
      "7m 10M 13m 16m 17M"
    ],
    "7b9b5" => ["3M 7m 9m 10M 12d", "3M 7m 9m 12d 14m", "7m 8P 10M 12d 16m", "7m 10M 12d 14m 16m"],
    "7b9sus" => ["1P 5P 7m 9m 11P", "5P 7m 8P 9m 11P", "7m 8P 11P 14m 16m"],
    "7sus" => [
      "1P 4P 6M 7m 9M",
      "1P 5P 7m 9M 11P",
      "4P 6M 7m 9M 11P",
      "5P 8P 9M 11P 14m",
      "7m 9M 11P 13M 15P",
      "7m 11P 12P 14m 18P"
    ],
    "7susadd3" => ["1P 4P 5P 7m 10M", "5P 8P 10M 11P 14m", "7m 11P 12P 15P 17M"],
    "9" => [
      "1P 6M 7m 9M 10M",
      "3M 7m 9M 10M 12P",
      "1P 7m 9M 10M 13M",
      "3M 7m 9M 10M 13M",
      "3M 7m 9M 12P 15P",
      "7m 10M 12P 13M 16M",
      "7m 10M 13M 16M 17M",
      "7m 10M 13M 16M 19P"
    ],
    "9#11" => ["1P 7m 9M 10M 12d", "3M 7m 8P 9M 12d", "7m 10M 12d 15P 16M"],
    "9#5" => [
      "1P 7m 9M 10M 13m",
      "3M 7m 9M 10M 13m",
      "3M 7m 9M 13m 14m",
      "7m 10M 13m 14m 16M",
      "7m 10M 13m 16M 17M"
    ],
    "9b5" => ["1P 7m 9M 10M 12d", "3M 7m 8P 9M 12d", "7m 10M 12d 15P 16M"],
    "9sus" => [
      "1P 4P 6M 7m 9M",
      "1P 5P 7m 9M 11P",
      "4P 6M 7m 9M 11P",
      "5P 8P 9M 11P 14m",
      "7m 9M 11P 13M 15P",
      "7m 11P 12P 14m 18P"
    ],
    "M" => [
      "1P 3M 5P 6M 9M",
      "1P 5P 8P 10M 12P",
      "3M 5P 9M 10M 12P",
      "1P 5P 8P 10M 13M",
      "3M 8P 10M 13M 15P",
      "5P 9M 10M 12P 15P"
    ],
    "M13" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "M7" => [
      "1P 6M 7M 9M 10M",
      "3M 7M 9M 10M 12P",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "M7#11" => [
      "1P 3M 5d 7M 9M",
      "1P 7M 9M 10M 12d",
      "3M 7M 9M 10M 12d",
      "3M 7M 9M 12d 13M",
      "3M 7M 10M 12d 14M",
      "7M 10M 12d 13M 14M",
      "7M 10M 12d 13M 16M",
      "7M 10M 12d 14M 17M"
    ],
    "M7#5" => [
      "1P 6m 7M 10M 13m",
      "3M 7M 9M 10M 13m",
      "3M 7M 10M 13m 14M",
      "7M 10M 13m 14M 16M",
      "7M 10M 13m 14M 17M"
    ],
    "M9" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "M9#11" => [
      "1P 3M 5d 7M 9M",
      "1P 7M 9M 10M 12d",
      "3M 7M 9M 10M 12d",
      "3M 7M 9M 12d 13M",
      "3M 7M 9M 12d 14M",
      "7M 10M 12d 14M 16M",
      "7M 10M 12d 13M 16M"
    ],
    "^" => [
      "1P 3M 5P 6M 9M",
      "1P 5P 8P 10M 12P",
      "3M 5P 9M 10M 12P",
      "1P 5P 8P 10M 13M",
      "3M 8P 10M 13M 15P",
      "5P 9M 10M 12P 15P"
    ],
    "^13" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "^7" => [
      "1P 6M 7M 9M 10M",
      "3M 7M 9M 10M 12P",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "^7#11" => [
      "1P 3M 5d 7M 9M",
      "1P 7M 9M 10M 12d",
      "3M 7M 9M 10M 12d",
      "3M 7M 9M 12d 13M",
      "3M 7M 10M 12d 14M",
      "7M 10M 12d 13M 14M",
      "7M 10M 12d 13M 16M",
      "7M 10M 12d 14M 17M"
    ],
    "^7#5" => [
      "1P 6m 7M 10M 13m",
      "3M 7M 9M 10M 13m",
      "3M 7M 10M 13m 14M",
      "7M 10M 13m 14M 16M",
      "7M 10M 13m 14M 17M"
    ],
    "^9" => [
      "1P 6M 7M 9M 10M",
      "1P 7M 9M 10M 13M",
      "3M 7M 9M 10M 13M",
      "3M 7M 9M 12P 13M",
      "3M 7M 8P 9M 13M",
      "3M 7M 9M 13M 14M",
      "3M 7M 10M 13M 16M",
      "7M 10M 13M 14M 16M",
      "7M 10M 13M 16M 17M",
      "7M 10M 13M 16M 19P"
    ],
    "^9#11" => [
      "1P 3M 5d 7M 9M",
      "1P 7M 9M 10M 12d",
      "3M 7M 9M 10M 12d",
      "3M 7M 9M 12d 13M",
      "3M 7M 9M 12d 14M",
      "7M 10M 12d 14M 16M",
      "7M 10M 12d 13M 16M"
    ],
    "add9" => [
      "1P 5P 8P 9M 10M",
      "1P 5P 9M 10M 12P",
      "3M 8P 9M 10M 12P",
      "3M 8P 9M 12P 15P",
      "5P 8P 9M 10M 15P",
      "5P 8P 9M 12P 17M"
    ],
    "aug" => [
      "1P 6m 8P 9M 10M",
      "1P 6m 8P 10M 13m",
      "3M 8P 9M 10M 13m",
      "3M 8P 10M 13m 15P",
      "6m 10M 13m 15P 16M",
      "6m 10M 13m 15P 17M"
    ],
    "h" => [
      "1P 5d 7m 10m 11P",
      "3m 5d 7m 8P 11P",
      "5d 7m 8P 10m 11P",
      "1P 7m 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 8P 10m 11P 14m",
      "7m 10m 11P 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "h7" => [
      "1P 5d 7m 10m 11P",
      "3m 5d 7m 8P 11P",
      "5d 7m 8P 10m 11P",
      "1P 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 8P 10m 11P 14m",
      "7m 10m 11P 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "h9" => [
      "3m 5d 7m 9M 11P",
      "1P 7m 9M 10m 12d",
      "3m 7m 9M 12d 14m",
      "5d 8P 9M 10m 14m",
      "7m 10m 11P 12d 14m",
      "7m 10m 12d 14m 16M"
    ],
    "m" => [
      "1P 3m 5P 8P 10m",
      "1P 3m 5P 9M 11P",
      "3m 5P 8P 9M 11P",
      "5P 8P 9M 10m 11P",
      "1P 5P 9M 10m 12P",
      "3m 5P 8P 10m 12P",
      "5P 8P 10m 12P 15P"
    ],
    "m#5" => ["1P 6m 8P 10m 13m", "3m 6m 8P 11P 13m", "6m 8P 10m 13m 15P"],
    "m11" => [
      "3m 5P 7m 9M 11P",
      "7m 9M 10m 11P",
      "1P 4P 7m 10m 12P",
      "3m 7m 9M 11P 12P",
      "7m 9M 10m 11P 12P",
      "3m 7m 9M 11P 14m",
      "4P 10m 12P 14m",
      "5P 8P 11P 14m",
      "5P 8P 11P 14m 16M",
      "7m 10m 12P 16M 18P",
      "7m 10m 11P 16M 21m"
    ],
    "m6" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "1P 5P 6M 10m 11P",
      "3m 5P 6M 8P 11P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 10m 11P 13M",
      "5P 8P 10m 13M 16M"
    ],
    "m69" => [
      "1P 3m 5P 6M 9M",
      "3m 5P 6M 8P 9M",
      "3m 6M 9M 10m 12P",
      "1P 5P 9M 10m 13M",
      "3m 5P 8P 9M 13M",
      "5P 8P 9M 10m 13M",
      "5P 8P 10m 13M 16M"
    ],
    "m7" => [
      "1P 3m 5P 7m 9M",
      "1P 3m 5P 7m 10m",
      "1P 5P 7m 10m 11P",
      "3m 7m 8P 10m 11P",
      "1P 5P 7m 10m 12P",
      "3m 7m 9M 10m 12P",
      "3m 7m 8P 10m 14m",
      "5P 7m 9M 10m 14m",
      "7m 10m 11P 14m 15P",
      "7m 10m 12P 15P 16M",
      "5P 8P 11P 14m 17m",
      "7m 10m 12P 15P 17m"
    ],
    "m7b5" => [
      "1P 5d 7m 10m 11P",
      "3m 5d 7m 8P 11P",
      "5d 7m 8P 10m 11P",
      "1P 7m 10m 12d",
      "3m 7m 8P 10m 12d",
      "3m 7m 8P 12d 14m",
      "5d 8P 10m 11P 14m",
      "7m 10m 11P 12d 14m",
      "7m 10m 12d 14m 15P",
      "5d 8P 10m 14m 17m"
    ],
    "m9" => [
      "1P 3m 5P 7m 9M",
      "1P 3m 7m 9M 11P",
      "3m 7m 9M 10m 11P",
      "3m 7m 9M 10m 12P",
      "3m 7m 9M 10m 14m",
      "3m 7m 9M 12P 15P",
      "7m 10m 11P 14m 16M",
      "7m 10m 12P 16M 18P"
    ],
    "m^7" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "m^9" => [
      "1P 3m 5P 7M 9M",
      "1P 5P 7M 10m 11P",
      "3m 7M 9M 10m 11P",
      "3m 7M 9M 10m 12P",
      "3m 7M 9M 12P 14M",
      "7M 10m 11P 12P 14M",
      "7M 10m 12P 14M 16M"
    ],
    "madd9" => ["1P 2M 3m 5P 8P", "1P 3m 5P 9M", "3m 5P 8P 9M 12P", "5P 8P 9M 10m 12P"],
    "mb6" => ["1P 3m 5P 6m 8P", "3m 5P 8P 11P 13m", "5P 8P 10m 11P 13m"],
    "o" => [
      "1P 6M 8P 10m 12d",
      "1P 6M 10m 12d 13M",
      "3m 8P 10m 12d 13M",
      "3m 8P 12d 13M 15P",
      "5d 10m 12d 13M 15P",
      "5d 10m 13M 15P 17m",
      "6M 12d 13M 15P 17m",
      "6M 12d 15P 17m 19d"
    ],
    "o7" => [
      "1P 6M 8P 10m 12d",
      "1P 6M 10m 12d 13M",
      "3m 8P 10m 12d 13M",
      "3m 8P 12d 13M 15P",
      "5d 10m 12d 13M 15P",
      "5d 10m 13M 15P 17m",
      "6M 12d 13M 15P 17m",
      "6M 12d 15P 17m 19d"
    ],
    "sus" => [
      "1P 4P 5P 8P 9M",
      "1P 4P 5P 8P 11P",
      "1P 5P 8P 9M 11P",
      "5P 8P 9M 11P 12P",
      "5P 8P 11P 12P 13M",
      "5P 8P 11P 13M 15P"
    ]
  }

  @doc "The `ireal` dictionary."
  @spec simple() :: %{String.t() => [String.t()]}
  def simple, do: @simple

  @doc "The `ireal-ext` dictionary."
  @spec complex() :: %{String.t() => [String.t()]}
  def complex, do: @complex
end
