defmodule TuningFork.PatternTest do
  @moduledoc """
  The query engine, checked by asking patterns about stretches of time.

  Most assertions go through `first_cycle/2`, which reports onsets as `{from, to, value}`. The
  ones that matter for playback query odd spans directly — across a cycle line, across a block
  boundary, at a single instant — because that is what a player actually does.
  """

  use ExUnit.Case, async: true

  alias TuningFork.Pattern, as: P

  doctest TuningFork.Pattern

  describe "the simplest patterns" do
    test "pure fills a cycle, once per cycle, forever" do
      assert P.first_cycle(P.pure(:bd)) == [{0.0, 1.0, :bd}]
      assert P.first_cycle(P.pure(:bd), 99) == [{0.0, 1.0, :bd}]
    end

    test "silence has nothing in it, however hard it is asked" do
      assert P.query(P.silence(), {0.0, 100.0}) == []
    end

    test "stack puts them all at once" do
      assert P.first_cycle(P.stack([P.pure(:bd), P.pure(:hh)])) == [
               {0.0, 1.0, :bd},
               {0.0, 1.0, :hh}
             ]
    end

    test "stack of nothing is silence, so it folds cleanly" do
      assert P.query(P.stack([]), {0.0, 4.0}) == []
    end
  end

  describe "putting things in order" do
    test "fastcat divides one cycle between them" do
      assert P.first_cycle(P.fastcat([:a, :b, :c, :d])) == [
               {0.0, 0.25, :a},
               {0.25, 0.5, :b},
               {0.5, 0.75, :c},
               {0.75, 1.0, :d}
             ]
    end

    test "fastcat takes bare values as well as patterns" do
      mixed = P.fastcat([:a, P.fastcat([:b, :c])])

      assert P.first_cycle(mixed) == [{0.0, 0.5, :a}, {0.5, 0.75, :b}, {0.75, 1.0, :c}]
    end

    test "slowcat takes a cycle each, and keeps its place as cycles go by" do
      pattern = P.slowcat([P.pure(:a), P.pure(:b), P.pure(:c)])

      assert P.first_cycle(pattern, 0) == [{0.0, 1.0, :a}]
      assert P.first_cycle(pattern, 1) == [{0.0, 1.0, :b}]
      assert P.first_cycle(pattern, 2) == [{0.0, 1.0, :c}]
      assert P.first_cycle(pattern, 3) == [{0.0, 1.0, :a}]
      assert P.first_cycle(pattern, 100) == [{0.0, 1.0, :b}]
    end

    test "a nested pattern under slowcat plays at its own speed, not squeezed" do
      pattern = P.slowcat([P.fastcat([:a, :b]), P.pure(:c)])

      assert P.first_cycle(pattern, 0) == [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
      assert P.first_cycle(pattern, 1) == [{0.0, 1.0, :c}]
    end
  end

  describe "bending time" do
    test "fast repeats it within the cycle" do
      assert P.first_cycle(P.fast(P.pure(:x), 4)) == [
               {0.0, 0.25, :x},
               {0.25, 0.5, :x},
               {0.5, 0.75, :x},
               {0.75, 1.0, :x}
             ]
    end

    test "slow stretches it across several" do
      pattern = P.slow(P.fastcat([:a, :b]), 2)

      assert P.first_cycle(pattern, 0) == [{0.0, 1.0, :a}]
      assert P.first_cycle(pattern, 1) == [{0.0, 1.0, :b}]
    end

    test "fast and slow undo each other" do
      pattern = P.fastcat([:a, :b, :c])

      assert P.first_cycle(P.slow(P.fast(pattern, 3), 3)) == P.first_cycle(pattern)
    end

    test "a factor of zero or less is silence rather than a crash" do
      assert P.query(P.fast(P.pure(:x), 0), {0.0, 4.0}) == []
      assert P.query(P.fast(P.pure(:x), -2), {0.0, 4.0}) == []
      assert P.query(P.slow(P.pure(:x), 0), {0.0, 4.0}) == []
    end

    test "rev turns the cycle round" do
      assert P.first_cycle(P.rev(P.fastcat([:a, :b, :c]))) == [
               {0.0, 0.333333, :c},
               {0.333333, 0.666667, :b},
               {0.666667, 1.0, :a}
             ]
    end

    test "rev twice is where it started" do
      pattern = P.fastcat([:a, :b, :c, :d])

      assert P.first_cycle(P.rev(P.rev(pattern))) == P.first_cycle(pattern)
    end

    test "shift turns the wheel rather than delaying it once" do
      shifted = P.shift(P.fastcat([:a, :b]), 0.25)

      assert P.first_cycle(shifted) == [{0.25, 0.75, :a}, {0.75, 1.25, :b}]
      assert P.first_cycle(shifted, 1) == [{0.25, 0.75, :a}, {0.75, 1.25, :b}]
    end
  end

  describe "changing with the cycle" do
    test "every fires on the cycles that divide, and leaves the others alone" do
      pattern = P.every(3, &P.rev/1, P.fastcat([:a, :b]))

      assert P.first_cycle(pattern, 0) == [{0.0, 0.5, :b}, {0.5, 1.0, :a}]
      assert P.first_cycle(pattern, 1) == [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
      assert P.first_cycle(pattern, 2) == [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
      assert P.first_cycle(pattern, 3) == [{0.0, 0.5, :b}, {0.5, 1.0, :a}]
    end

    test "when_cycle takes any test of the cycle number" do
      pattern = P.when_cycle(&(&1 > 2), &P.rev/1, P.fastcat([:a, :b]))

      assert P.first_cycle(pattern, 2) == [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
      assert P.first_cycle(pattern, 3) == [{0.0, 0.5, :b}, {0.5, 1.0, :a}]
    end

    test "superimpose lays a changed copy over the original" do
      doubled = P.superimpose(P.pure(:a), &P.fast(&1, 2))

      assert P.first_cycle(doubled) == [{0.0, 0.5, :a}, {0.0, 1.0, :a}, {0.5, 1.0, :a}]
    end

    test "off lays it over a fraction of a cycle behind" do
      echoed = P.off(P.pure(:a), 0.25, &P.with_value(&1, fn _ -> :echo end))

      assert P.first_cycle(echoed) == [{0.0, 1.0, :a}, {0.25, 1.25, :echo}]
    end
  end

  describe "euclidean rhythms" do
    test "the ones everybody knows" do
      assert P.bjorklund(3, 8) == [true, false, false, true, false, false, true, false]
      assert P.bjorklund(5, 8) == [true, false, true, true, false, true, true, false]
      assert P.bjorklund(2, 5) == [true, false, true, false, false]
      assert P.bjorklund(4, 4) == [true, true, true, true]
    end

    test "no hits is silence and every hit is every step" do
      assert P.bjorklund(0, 4) == [false, false, false, false]
      assert P.bjorklund(9, 4) == [true, true, true, true]
    end

    test "the rests are silence, so a euclidean pattern stacks over another" do
      assert P.first_cycle(P.euclid(P.pure(:bd), 3, 8)) == [
               {0.0, 0.125, :bd},
               {0.375, 0.5, :bd},
               {0.75, 0.875, :bd}
             ]
    end

    test "a negative count sounds on the rests instead" do
      inverted = P.first_cycle(P.euclid(P.pure(:x), -3, 8))

      assert length(inverted) == 5
      refute Enum.any?(inverted, fn {from, _to, _value} -> from == 0.0 end)
    end
  end

  describe "combining structure" do
    test "app_left keeps the left wholes and cuts their parts where the right changes" do
      combined =
        P.app_left(P.fastcat([:a, :b]), P.fastcat([1, 2, 3]), fn left, right -> {left, right} end)

      assert P.first_cycle(combined) == [{0.0, 0.5, {:a, 1}}, {0.5, 1.0, {:b, 2}}]
      assert length(P.query(combined, {0.0, 1.0})) == 4

      assert [%{whole: {0.5, 1.0}, part: {part_from, 1.0}, value: {:b, 3}}] =
               P.query(combined, {0.7, 1.0})

      assert_in_delta part_from, 0.7, 0.0001
    end

    test "app_left against a signal reads the signal once per left event" do
      combined = P.app_left(P.fastcat([:a, :b]), P.saw(), fn left, right -> {left, right} end)

      assert [{_, _, {:a, first}}, {_, _, {:b, second}}] = P.first_cycle(combined)
      assert_in_delta first, 0.0, 0.0001
      assert_in_delta second, 0.5, 0.0001
    end

    test "segment on a discrete pattern reads what is sounding at each step" do
      assert P.first_cycle(P.segment(P.fastcat([:a, :b, :c]), 2)) == [
               {0.0, 0.5, :a},
               {0.5, 1.0, :b}
             ]

      assert P.first_cycle(P.segment(P.fastcat([:a, :b]), 4)) == [
               {0.0, 0.25, :a},
               {0.25, 0.5, :a},
               {0.5, 0.75, :b},
               {0.75, 1.0, :b}
             ]
    end
  end

  describe "clip" do
    test "takes a pattern of amounts" do
      assert P.first_cycle(P.clip(P.fastcat([:a, :b]), P.fastcat([0.5, 1]))) == [
               {0.0, 0.25, :a},
               {0.5, 1.0, :b}
             ]
    end
  end

  describe "signals" do
    test "a signal has a value at any instant and no onset of its own" do
      assert [%{whole: nil, value: value}] = P.query(P.saw(), {0.25, 0.25})
      assert_in_delta value, 0.25, 0.0001
      assert P.first_cycle(P.saw()) == []
    end

    test "segment gives a signal a shape" do
      assert P.first_cycle(P.segment(P.saw(), 4)) == [
               {0.0, 0.25, 0.0},
               {0.25, 0.5, 0.25},
               {0.5, 0.75, 0.5},
               {0.75, 1.0, 0.75}
             ]
    end

    test "sine and tri stay between zero and one" do
      for pattern <- [P.sine(), P.tri(), P.rand()] do
        values = P.segment(pattern, 16) |> P.first_cycle() |> Enum.map(&elem(&1, 2))

        assert length(values) == 16
        assert Enum.all?(values, &(&1 >= 0.0 and &1 <= 1.0))
      end
    end

    test "range stretches it onto whatever is wanted" do
      values = P.saw() |> P.range(100, 900) |> P.segment(4) |> P.first_cycle()

      assert values == [
               {0.0, 0.25, 100.0},
               {0.25, 0.5, 300.0},
               {0.5, 0.75, 500.0},
               {0.75, 1.0, 700.0}
             ]
    end

    test "rand does not repeat within a cycle but replays the same every run" do
      values = P.rand() |> P.segment(8) |> P.first_cycle() |> Enum.map(&elem(&1, 2))

      assert length(Enum.uniq(values)) == 8
      assert values == P.rand() |> P.segment(8) |> P.first_cycle() |> Enum.map(&elem(&1, 2))
    end

    test "a different seed gives a different sequence" do
      one = P.rand(1) |> P.segment(8) |> P.first_cycle()
      other = P.rand(2) |> P.segment(8) |> P.first_cycle()

      refute one == other
    end
  end

  describe "dropping events" do
    test "degrade keeps roughly what it says and always the same ones" do
      dense = P.fast(P.pure(:hh), 64)
      kept = P.degrade(dense, 0.5) |> P.first_cycle() |> length()

      assert kept > 20 and kept < 44
      assert P.first_cycle(P.degrade(dense, 0.5)) == P.first_cycle(P.degrade(dense, 0.5))
    end

    test "degrading by nothing keeps everything and by everything keeps none" do
      dense = P.fast(P.pure(:hh), 16)

      assert length(P.first_cycle(P.degrade(dense, 0.0))) == 16
      assert P.first_cycle(P.degrade(dense, 1.1)) == []
    end
  end

  describe "what a player sees" do
    test "an event cut by a block boundary comes back as two parts of one whole" do
      pattern = P.pure(:long)

      [first] = P.query(pattern, {0.0, 0.5})
      [second] = P.query(pattern, {0.5, 1.0})

      assert first.whole == {0.0, 1.0}
      assert second.whole == {0.0, 1.0}
      assert first.part == {0.0, 0.5}
      assert second.part == {0.5, 1.0}
    end

    test "only the first of those fragments is an onset, so a note triggers once" do
      pattern = P.pure(:long)

      assert [event] = P.query(pattern, {0.0, 0.5})
      assert P.onset?(event)

      assert [event] = P.query(pattern, {0.5, 1.0})
      refute P.onset?(event)
    end

    test "a query across a cycle line reports each cycle's events once" do
      pattern = P.fastcat([:a, :b])

      onsets =
        pattern
        |> P.query({0.75, 1.75})
        |> Enum.filter(&P.onset?/1)
        |> Enum.map(& &1.value)

      assert onsets == [:a, :b]
    end

    test "asking block by block sees every onset exactly once" do
      pattern = P.stack([P.euclid(P.pure(:bd), 3, 8), P.fast(P.pure(:hh), 4)])

      block_by_block =
        Enum.flat_map(0..31, fn block ->
          from = block / 32
          pattern |> P.query({from, from + 1 / 32}) |> Enum.filter(&P.onset?/1)
        end)

      in_one_go = pattern |> P.query({0.0, 1.0}) |> Enum.filter(&P.onset?/1)

      assert length(block_by_block) == length(in_one_go)
    end
  end

  describe "swapping a pattern while it plays" do
    test "the new one answers for the cycle actually being played, not from the top" do
      was = P.fastcat([:a, :b])
      now = P.fastcat([:x, :y, :z])

      assert P.first_cycle(now, 97) == [
               {0.0, 0.333333, :x},
               {0.333333, 0.666667, :y},
               {0.666667, 1.0, :z}
             ]

      assert P.first_cycle(was, 97) == [{0.0, 0.5, :a}, {0.5, 1.0, :b}]
    end

    test "a pattern that counts cycles keeps counting through a swap" do
      before = P.every(4, &P.rev/1, P.fastcat([:a, :b]))
      swapped = P.every(4, &P.rev/1, P.fastcat([:c, :d]))

      assert P.first_cycle(before, 8) == [{0.0, 0.5, :b}, {0.5, 1.0, :a}]
      assert P.first_cycle(swapped, 8) == [{0.0, 0.5, :d}, {0.5, 1.0, :c}]
      assert P.first_cycle(swapped, 9) == [{0.0, 0.5, :c}, {0.5, 1.0, :d}]
    end
  end

  defp values(pattern, cycle \\ 0) do
    pattern |> P.first_cycle(cycle) |> Enum.map(&elem(&1, 2))
  end

  describe "signals beyond sine and saw" do
    test "isaw falls where saw rises" do
      [saw | _] = values(P.segment(P.saw(), 4))
      [isaw | _] = values(P.segment(P.isaw(), 4))

      assert_in_delta saw + isaw, 1.0, 0.001
    end

    test "square is low for the first half and high for the second" do
      assert values(P.segment(P.square(), 4)) == [0.0, 0.0, 1.0, 1.0]
    end

    test "irand gives whole numbers inside the range" do
      got = values(P.segment(P.irand(8), 16))

      assert length(got) == 16
      assert Enum.all?(got, &(&1 in 0..7))
      assert length(Enum.uniq(got)) > 1, "it should actually vary"
    end

    test "brand_by is true about as often as it was asked to be" do
      trues = P.segment(P.brand_by(0.25), 200) |> P.first_cycle() |> Enum.count(&elem(&1, 2))

      assert trues in 25..75, "about a quarter of 200, got #{trues}"
    end

    test "choose picks from the list and nothing else" do
      got = values(P.segment(P.choose([:x, :y, :z]), 32))

      assert Enum.all?(got, &(&1 in [:x, :y, :z]))
      assert length(Enum.uniq(got)) == 3
    end

    test "wchoose favours the heavier choice" do
      got = values(P.segment(P.wchoose([{9, :common}, {1, :rare}]), 100))

      assert Enum.count(got, &(&1 == :common)) > Enum.count(got, &(&1 == :rare)) * 3
    end

    test "choose_cycles holds one value for a whole cycle" do
      pattern = P.choose_cycles([:x, :y, :z])

      for cycle <- 0..5 do
        assert [{from, to, value}] = P.first_cycle(pattern, cycle)
        assert {from, to} == {0.0, 1.0}
        assert value in [:x, :y, :z]
      end
    end
  end

  describe "the sometimes family" do
    defp marked(pattern, cycles \\ 40) do
      tagged =
        for cycle <- 0..(cycles - 1), {_from, _to, value} <- P.first_cycle(pattern, cycle) do
          value
        end

      Enum.count(tagged, &(&1 == :marked))
    end

    defp tag(pattern), do: P.with_value(pattern, fn _value -> :marked end)

    test "the fixed chances sit in the order their names claim" do
      pattern = P.fast(P.pure(:x), 8)

      assert marked(P.never(pattern, &tag/1)) == 0
      assert marked(P.always(pattern, &tag/1)) == 320

      assert marked(P.almost_never(pattern, &tag/1)) <
               marked(P.rarely(pattern, &tag/1)) and
               marked(P.rarely(pattern, &tag/1)) < marked(P.sometimes(pattern, &tag/1)) and
               marked(P.sometimes(pattern, &tag/1)) < marked(P.often(pattern, &tag/1)) and
               marked(P.often(pattern, &tag/1)) < marked(P.almost_always(pattern, &tag/1))
    end

    test "undegrade keeps exactly what degrade drops" do
      pattern = P.fast(P.pure(:x), 16)

      kept = length(P.first_cycle(P.degrade_by(pattern, 0.4)))
      dropped = length(P.first_cycle(P.undegrade_by(pattern, 0.4)))

      assert kept + dropped == 16
    end

    test "some_cycles changes whole cycles rather than single events" do
      pattern = P.some_cycles(P.fastcat([:a, :b, :c, :d]), &P.rev/1)

      for cycle <- 0..9 do
        assert values(pattern, cycle) in [[:a, :b, :c, :d], [:d, :c, :b, :a]],
               "cycle #{cycle} should be all one way or all the other"
      end
    end
  end

  describe "moving time about" do
    test "palindrome alternates direction" do
      pattern = P.palindrome(P.fastcat([:a, :b]))

      assert values(pattern, 0) == [:a, :b]
      assert values(pattern, 1) == [:b, :a]
    end

    test "iter_back walks the other way from iter" do
      pattern = P.fastcat([:a, :b, :c, :d])

      assert values(P.iter(pattern, 4), 1) == [:b, :c, :d, :a]
      assert values(P.iter_back(pattern, 4), 1) == [:d, :a, :b, :c]
    end

    test "zoom plays the same slice on every cycle" do
      pattern = P.zoom(P.fastcat([:a, :b, :c, :d]), 0.25, 0.75)

      for cycle <- 0..3, do: assert(values(pattern, cycle) == [:b, :c])
    end

    test "linger repeats the opening to fill the cycle" do
      pattern = P.fastcat([:a, :b, :c, :d])

      assert values(P.linger(pattern, 0.5)) == [:a, :b, :a, :b]
      assert values(P.linger(pattern, 0.25)) == [:a, :a, :a, :a]
    end

    test "inside works on each half rather than the whole cycle" do
      assert values(P.inside(P.fastcat([:a, :b, :c, :d]), 2, &P.rev/1)) == [:b, :a, :d, :c]
    end

    test "swing pushes every other subdivision late" do
      [{first, _, _}, {second, _, _} | _] =
        P.first_cycle(P.swing_by(P.fastcat([1, 2, 3, 4]), 1 / 3, 2))

      assert first == 0.0, "the downbeat stays put"
      assert second > 0.25, "and the offbeat is pushed late"
    end

    test "ribbon loops one stretch of a longer pattern" do
      looped = P.ribbon(P.slowcat([P.pure(:a), P.pure(:b), P.pure(:c)]), 2, 1)

      for cycle <- 0..4, do: assert(P.first_cycle(looped, cycle) == [{0.0, 1.0, :c}])
    end

    test "clip shortens events without moving them" do
      assert P.first_cycle(P.clip(P.fastcat([:a, :b]), 0.5)) ==
               [{0.0, 0.25, :a}, {0.5, 0.75, :b}]
    end
  end

  describe "picking cycles and chunks apart" do
    test "last_of fires on the last of the group, first_of on the first" do
      pattern = P.fastcat([:a, :b])

      assert values(P.last_of(pattern, 2, &P.rev/1), 0) == [:a, :b]
      assert values(P.last_of(pattern, 2, &P.rev/1), 1) == [:b, :a]
      assert values(P.first_of(pattern, 2, &P.rev/1), 0) == [:b, :a]
    end

    test "chunk changes a different quarter each cycle and keeps the rest" do
      chunked = P.chunk(P.fastcat([:a, :b, :c, :d]), 4, &P.rev/1)

      assert values(chunked, 0) == [:d, :b, :c, :d]
      assert length(P.first_cycle(chunked, 1)) == 4
    end

    test "chunk_back walks the chunks the other way" do
      assert values(P.chunk_back(P.fastcat([:a, :b, :c, :d]), 4, &P.rev/1)) == [:a, :b, :c, :a]
    end

    test "fast_chunk fits every chunk into one cycle" do
      assert length(P.first_cycle(P.fast_chunk(P.fastcat([:a, :b, :c, :d]), 4, &P.rev/1))) == 16
    end
  end

  describe "laying copies over a pattern" do
    test "layer stacks every function given" do
      assert length(P.first_cycle(P.layer(P.fastcat([:a, :b]), [& &1, &P.rev/1]))) == 4
    end

    test "stut makes delayed copies" do
      assert length(P.first_cycle(P.stut(P.pure(:x), 3, 0.1))) == 3
    end

    test "echo_with is handed the copy number" do
      pattern = P.echo_with(P.pure(0), 3, 0.1, fn copy, step -> P.add(copy, step) end)

      assert pattern |> values() |> Enum.sort() == [0, 1, 2]
    end
  end

  describe "arithmetic on values" do
    test "add takes a number" do
      assert values(P.add(P.fastcat([0, 2]), 12)) == [12, 14]
    end

    test "add takes another pattern, keeping the left's timing" do
      assert values(P.add(P.fastcat([0, 2, 4, 6]), P.fastcat([0, 10]))) == [0, 2, 14, 16]
    end

    test "sub, mul and divide do the obvious" do
      assert values(P.sub(P.pure(12), 2)) == [10]
      assert values(P.mul(P.pure(12), 2)) == [24]
      assert values(P.divide(P.pure(12), 2)) == [6.0]
    end

    test "dividing by nothing leaves the value alone rather than raising" do
      assert values(P.divide(P.pure(3), 0)) == [3]
    end

    test "control maps add key by key, leaving the rest alone" do
      assert values(P.add(P.pure(%{note: 60, s: "piano"}), %{note: 12})) ==
               [%{note: 72, s: "piano"}]
    end
  end

  describe "building blocks" do
    test "run counts up across the cycle" do
      assert values(P.run(4)) == [0, 1, 2, 3]
    end

    test "binary spells a number out in bits" do
      assert values(P.binary(5)) == [false, true, false, true]
      assert length(P.first_cycle(P.binary(5, 8))) == 8
    end

    test "arrange gives each part the cycles it asks for" do
      pattern = P.arrange([{2, P.pure(:a)}, {1, P.pure(:b)}])

      assert values(pattern, 0) == [:a]
      assert values(pattern, 1) == [:a]
      assert values(pattern, 2) == [:b]
    end

    test "polymeter steps both patterns at the same rate" do
      three = P.fastcat([:a, :b, :c])
      four = P.fastcat([1, 2, 3, 4])

      assert length(P.first_cycle(P.polymeter([{3, three}, {4, four}], 4))) == 8
    end

    test "squeeze fits a whole pattern into each event" do
      assert values(P.squeeze(P.fastcat([:x, :y]), P.fastcat([1, 2]))) == [1, 2, 1, 2]
    end
  end

  describe "counting in steps" do
    test "a sequence is as many steps as it has top-level items" do
      assert P.steps(P.fastcat([:a, :b, :c])) == 3
      assert P.steps(P.pure(:a)) == 1
    end

    test "mini-notation counts the top level, whatever is nested inside it" do
      alias TuningFork.Pattern.Mini

      assert P.steps(Mini.parse("a b c")) == 3
      assert P.steps(Mini.parse("a [b c] d e")) == 4
      assert P.steps(Mini.parse("<a b>")) == 1
      assert P.steps(Mini.parse("a@3 b")) == 4
    end

    test "stepcat gives each pattern room in proportion to its steps" do
      three = P.fastcat([:a, :b, :c])
      two = P.fastcat([:d, :e])
      joined = P.stepcat([three, two])

      assert values(joined) == [:a, :b, :c, :d, :e]
      assert P.steps(joined) == 5

      widths =
        joined |> P.first_cycle() |> Enum.map(fn {from, to, _v} -> Float.round(to - from, 6) end)

      assert length(Enum.uniq(widths)) == 1, "every step should be the same length"
    end

    test "pace plays it at so many steps a cycle whatever it was written as" do
      assert values(P.pace(P.fastcat([:a, :b, :c, :d]), 2)) == [:a, :b]
      assert P.steps(P.pace(P.fastcat([:a, :b, :c, :d]), 2)) == 2
    end

    test "expand and contract change the count without changing the sound" do
      three = P.fastcat([:a, :b, :c])

      assert values(P.expand(three, 2)) == values(three)
      assert P.steps(P.expand(three, 2)) == 6
      assert P.steps(P.contract(three, 3)) == 1.0
    end

    test "expanding one side of a stepcat gives it more room" do
      three = P.fastcat([:a, :b, :c])
      two = P.fastcat([:d, :e])

      plain = P.stepcat([three, two]) |> P.first_cycle() |> Enum.map(&elem(&1, 1)) |> Enum.at(2)
      wider = P.stepcat([P.expand(three, 2), two])

      assert P.steps(wider) == 8
      assert wider |> P.first_cycle() |> Enum.map(&elem(&1, 1)) |> Enum.at(2) > plain
    end

    test "extend plays it over again and counts it as that much more" do
      extended = P.extend(P.fastcat([:a, :b, :c]), 2)

      assert values(extended) == [:a, :b, :c, :a, :b, :c]
      assert P.steps(extended) == 6
    end

    test "take and drop count from either end" do
      four = P.fastcat([:a, :b, :c, :d])

      assert values(P.take(four, 2)) == [:a, :b]
      assert values(P.take(four, -2)) == [:c, :d]
      assert values(P.drop(four, 2)) == [:c, :d]
      assert values(P.drop(four, -2)) == [:a, :b]
    end

    test "taking more than there is gives the whole of it, and none gives nothing" do
      four = P.fastcat([:a, :b, :c, :d])

      assert values(P.take(four, 9)) == [:a, :b, :c, :d]
      assert P.first_cycle(P.take(four, 0)) == []
      assert P.first_cycle(P.drop(four, 9)) == []
    end

    test "shrink wears the phrase down and grow builds it up" do
      three = P.fastcat([:a, :b, :c])

      assert values(P.shrink(three)) == [:a, :b, :c, :a, :b, :a]
      assert values(P.grow(three)) == [:a, :a, :b, :a, :b, :c]
    end

    test "zip takes one step from each in turn" do
      assert values(P.zip([P.fastcat([:a, :b]), P.fastcat([1, 2])])) == [:a, 1, :b, 2]
    end

    test "tour appends each variation in turn, a cycle at a time" do
      toured = P.tour(P.fastcat([:a, :b]), [P.pure(:x), P.pure(:y)])

      assert values(toured, 0) == [:a, :b, :x]
      assert values(toured, 1) == [:a, :b, :y]
    end
  end

  describe "choosing between whole patterns" do
    test "pick takes the pattern its index names" do
      picked = P.pick(P.slowcat([P.pure(0), P.pure(1)]), [P.pure(:x), P.pure(:y)])

      assert values(picked, 0) == [:x]
      assert values(picked, 1) == [:y]
    end

    test "an index past the end wraps round" do
      picked = P.pick(P.pure(5), [P.pure(:x), P.pure(:y)])

      assert values(picked) == [:y]
    end

    test "invert turns true and false inside out and leaves the rest alone" do
      assert values(P.invert(P.binary(5))) == [true, false, true, false]
      assert values(P.invert(P.pure(:a))) == [:a]
    end

    test "perlin drifts rather than jumping" do
      steps = P.segment(P.perlin(), 16) |> P.first_cycle() |> Enum.map(&elem(&1, 2))
      jumps = steps |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> abs(b - a) end)

      assert Enum.all?(steps, &(&1 >= 0.0 and &1 <= 1.0))
      assert Enum.max(jumps) < 0.3, "a smooth signal should not leap about"
    end

    test "wchoose_cycles holds one weighted choice for a whole cycle" do
      pattern = P.wchoose_cycles([{9, :common}, {1, :rare}])

      for cycle <- 0..9 do
        assert [{from, to, value}] = P.first_cycle(pattern, cycle)
        assert {from, to} == {0.0, 1.0}
        assert value in [:common, :rare]
      end
    end
  end

  describe "squeezing a pattern into each value" do
    test "squeeze_values fits a whole pattern into every event" do
      pattern = P.squeeze_values(P.fastcat([2, 3]), &P.fastcat(Enum.to_list(1..&1)))

      assert values(pattern) == [1, 2, 1, 2, 3]
    end

    test "it works past the first cycle, not only in cycle zero" do
      pattern = P.squeeze_values(P.pure(2), fn n -> P.fastcat(Enum.to_list(1..n)) end)

      assert values(pattern, 0) == [1, 2]
      assert values(pattern, 3) == [1, 2]
    end
  end

  describe "euclid and arpeggios" do
    test "euclid_rot is euclid turned round" do
      plain = P.first_cycle(P.euclid(P.pure(:x), 3, 8))
      turned = P.first_cycle(P.euclid_rot(P.pure(:x), 3, 8, 1))

      assert length(plain) == 3
      assert length(turned) == 3
      refute plain == turned
    end

    test "euclid_legato holds each hit until the next" do
      legato = P.first_cycle(P.euclid_legato(P.pure(:x), 3, 8))

      assert length(legato) == 3

      widths = Enum.map(legato, fn {from, to, _value} -> to - from end)
      assert Enum.sum(widths) > 0.99, "the hits should fill the cycle between them"
    end

    test "arp spreads a chord out in order" do
      chord = P.stack([P.pure(3), P.pure(1), P.pure(2)])

      assert values(P.arp(chord, :up)) == [1, 2, 3]
      assert values(P.arp(chord, :down)) == [3, 2, 1]
    end

    test "arp_with takes its own ordering" do
      chord = P.stack([P.pure(1), P.pure(2)])

      assert length(P.first_cycle(P.arp_with(chord, fn values -> values ++ values end))) == 4
    end
  end
end
