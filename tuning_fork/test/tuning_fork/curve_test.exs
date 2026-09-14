defmodule TuningFork.CurveTest do
  use ExUnit.Case, async: true

  alias TuningFork.Curve

  describe "reading a curve" do
    test "a single point is that value everywhere" do
      curve = Curve.hold(2.0)

      assert Curve.at(curve, 0.0) == 2.0
      assert Curve.at(curve, 0.5) == 2.0
      assert Curve.at(curve, 1.0) == 2.0
    end

    test "a straight line arrives where it was told to" do
      curve = Curve.linear(1.0, 2.0)

      assert Curve.at(curve, 0.0) == 1.0
      assert Curve.at(curve, 1.0) == 2.0
    end

    test "between breakpoints it interpolates" do
      curve = Curve.linear(1.0, 2.0)

      assert_in_delta Curve.at(curve, 0.5), 1.5, 0.0001
      assert_in_delta Curve.at(curve, 0.25), 1.25, 0.0001
    end

    test "it holds flat either side rather than running off" do
      curve = Curve.new([{0.25, 1.0}, {0.75, 2.0}])

      assert Curve.at(curve, 0.0) == 1.0
      assert Curve.at(curve, 0.1) == 1.0
      assert Curve.at(curve, 0.9) == 2.0
      assert Curve.at(curve, 5.0) == 2.0
    end

    test "several segments each read on their own" do
      curve = Curve.new([{0.0, 0.0}, {0.5, 1.0}, {1.0, 0.0}])

      assert_in_delta Curve.at(curve, 0.25), 0.5, 0.0001
      assert_in_delta Curve.at(curve, 0.5), 1.0, 0.0001
      assert_in_delta Curve.at(curve, 0.75), 0.5, 0.0001
    end

    test "points given out of order are sorted rather than misread" do
      curve = Curve.new([{1.0, 2.0}, {0.0, 1.0}])

      assert Curve.at(curve, 0.0) == 1.0
      assert Curve.at(curve, 1.0) == 2.0
    end
  end

  describe "noticing a curve does nothing" do
    test "no curve at all is flat" do
      assert Curve.flat?(nil)
    end

    test "one point is flat" do
      assert Curve.flat?(Curve.hold(1.0))
    end

    test "several points at the same value are flat" do
      assert Curve.flat?(Curve.new([{0.0, 1.0}, {0.5, 1.0}, {1.0, 1.0}]))
    end

    test "a line that goes somewhere is not" do
      refute Curve.flat?(Curve.linear(1.0, 1.5))
    end
  end

  describe "thinning a curve" do
    test "a curve already small enough is left alone" do
      curve = Curve.linear(1.0, 2.0)

      assert Curve.simplify(curve, 8) == curve
    end

    test "it comes back at the length asked for" do
      dense = Curve.new(for i <- 0..100, do: {i / 100, :math.sin(i / 100 * :math.pi())})

      assert length(Curve.simplify(dense, 8)) == 8
    end

    test "the ends are kept, because they are where the note starts and finishes" do
      dense = Curve.new(for i <- 0..50, do: {i / 50, i / 50})
      thin = Curve.simplify(dense, 4)

      assert List.first(thin) == {0.0, 0.0}
      assert List.last(thin) == {1.0, 1.0}
    end

    test "a straight line thins to its ends without losing anything" do
      dense = Curve.new(for i <- 0..50, do: {i / 50, 1.0 + i / 50})
      thin = Curve.simplify(dense, 2)

      for progress <- [0.0, 0.13, 0.5, 0.87, 1.0] do
        assert_in_delta Curve.at(thin, progress), Curve.at(dense, progress), 0.0001
      end
    end

    test "a shape keeps its peak rather than whatever fell next to it" do
      dense = Curve.new(for i <- 0..30, do: {i / 30, if(i == 20, do: 5.0, else: 1.0)})
      thin = Curve.simplify(dense, 5)

      assert_in_delta Curve.at(thin, 20 / 30), 5.0, 0.0001
    end

    test "asking for fewer than two breakpoints is refused by name" do
      dense = Curve.linear(1.0, 2.0)

      assert_raise ArgumentError, ~r/keeps at least 2 breakpoints/, fn ->
        Curve.simplify(dense, 1)
      end

      assert_raise ArgumentError, ~r/keeps at least 2 breakpoints/, fn ->
        Curve.simplify(dense, 0)
      end
    end

    test "a curve already that short is handed back rather than refused" do
      assert Curve.simplify(Curve.hold(2.0), 1) == Curve.hold(2.0)
    end
  end

  describe "a curve with no breakpoints" do
    test "is refused by name, pointing at the function that does what was meant" do
      assert_raise ArgumentError, ~r/at least one breakpoint.*hold\/1/s, fn -> Curve.new([]) end
    end
  end
end
