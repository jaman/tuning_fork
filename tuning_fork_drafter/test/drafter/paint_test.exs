defmodule TuningFork.Drafter.PaintTest do
  @moduledoc """
  The pixel drawings, asserted on as pixels.

  `at/3` reads one pixel out of a raster, so a test can say where a bar or a trace landed
  rather than trusting that something was drawn somewhere.
  """

  use ExUnit.Case, async: true

  alias FrenchCurve.Raster
  alias TuningFork.Drafter.Paint

  defp at(%Raster{} = raster, x, y), do: Raster.get_pixel(raster, x, y)

  defp lit?(raster, x, y) do
    {r, g, b, _a} = at(raster, x, y)

    r + g + b > 120
  end

  defp any_lit?(raster, x) do
    Enum.any?(0..(raster.height - 1), &lit?(raster, x, &1))
  end

  describe "the pianoroll" do
    test "it is the size it was asked for" do
      roll = Paint.pianoroll([], 0.0, width: 200, height: 40)

      assert Raster.dimensions(roll) == {200, 40}
    end

    test "a note is drawn where its cycle position says" do
      roll = Paint.pianoroll([{0.5, 0.6, 60}], 0.0, width: 200, height: 40, grid: false)

      assert any_lit?(roll, 105)
      refute any_lit?(roll, 20)
    end

    test "a longer note draws a longer box, though not the whole span" do
      short = Paint.pianoroll([{0.0, 0.1, 60}], 0.9, width: 200, height: 40, grid: false)
      long = Paint.pianoroll([{0.0, 0.9, 60}], 0.95, width: 200, height: 40, grid: false)

      assert any_lit?(long, 70)
      refute any_lit?(short, 70)
    end

    test "a note is drawn shorter than its span, so neighbours do not merge" do
      roll = Paint.pianoroll([{0.0, 0.5, 60}], 0.9, width: 200, height: 40, grid: false)

      assert any_lit?(roll, 40)
      refute any_lit?(roll, 95), "a note filling its whole span would butt against the next"
    end

    test "higher notes sit above lower ones" do
      roll =
        Paint.pianoroll([{0.0, 0.4, 48}, {0.5, 0.9, 84}], 0.0,
          width: 200,
          height: 40,
          grid: false
        )

      high = Enum.find(0..39, &lit?(roll, 120, &1))
      low = Enum.find(0..39, &lit?(roll, 20, &1))

      assert high < low, "the higher note should be nearer the top"
    end

    test "one note on its own still draws rather than dividing by no span" do
      roll = Paint.pianoroll([{0.0, 0.5, 60}], 0.0, width: 200, height: 40, grid: false)

      assert any_lit?(roll, 40)
    end

    test "the playhead is drawn where the cycle has reached" do
      roll = Paint.pianoroll([], 4.25, width: 200, height: 40, grid: false)

      assert any_lit?(roll, 50)
      refute any_lit?(roll, 150)
    end

    test "the grid marks the quarters, and can be turned off" do
      with_grid = Paint.pianoroll([], 0.0, width: 200, height: 40)
      without = Paint.pianoroll([], 0.0, width: 200, height: 40, grid: false)

      refute at(with_grid, 100, 20) == at(without, 100, 20)
    end

    test "nothing to draw is still a raster, not nothing" do
      assert %Raster{} = Paint.pianoroll([], 0.0)
    end
  end

  describe "hits with no pitch" do
    test "a bar fills the height, since there is no pitch axis to use" do
      drawn = Paint.hits([{0.0, 0.25}], 0.9, width: 200, height: 40, grid: false)

      assert lit?(drawn, 10, 4)
      assert lit?(drawn, 10, 35)
    end

    test "it is far more visible than putting them all on one pianoroll line" do
      as_hits = Paint.hits([{0.0, 0.25}], 0.9, width: 200, height: 40, grid: false)
      as_roll = Paint.pianoroll([{0.0, 0.25, 60}], 0.9, width: 200, height: 40, grid: false)

      assert count_lit(as_hits) > count_lit(as_roll) * 3
    end

    test "each hit lands where its position says" do
      drawn = Paint.hits([{0.5, 0.6}], 0.0, width: 200, height: 40, grid: false)

      assert any_lit?(drawn, 105)
      refute any_lit?(drawn, 20)
    end

    test "nothing to draw is still a raster" do
      assert %Raster{} = Paint.hits([], 0.0)
    end

    test "the playhead can be left out, so the picture only changes when the hits do" do
      still = Paint.hits([{0.0, 0.1}], 0.5, width: 200, height: 40, playhead: false, grid: false)
      moved = Paint.hits([{0.0, 0.1}], 0.9, width: 200, height: 40, playhead: false, grid: false)

      assert still == moved
    end
  end

  describe "leaving the playhead out" do
    test "the line goes, but which note is hollow still follows the phase" do
      without = Paint.pianoroll([{0.0, 0.5, 60}], 0.8, width: 200, height: 40, playhead: false)
      with_line = Paint.pianoroll([{0.0, 0.5, 60}], 0.8, width: 200, height: 40)

      refute without == with_line, "the line should be the difference"

      early = Paint.pianoroll([{0.0, 0.5, 60}], 0.1, width: 200, height: 40, playhead: false)

      refute without == early, "the sounding note is drawn differently, line or no line"
    end

    test "with it in, they do not" do
      one = Paint.pianoroll([{0.0, 0.5, 60}], 0.1, width: 200, height: 40)
      other = Paint.pianoroll([{0.0, 0.5, 60}], 0.8, width: 200, height: 40)

      refute one == other
    end
  end

  describe "the scope" do
    test "it is the size it was asked for" do
      assert Raster.dimensions(Paint.scope([], width: 300, height: 50)) == {300, 50}
    end

    test "silence draws the zero line down the middle" do
      scope = Paint.scope(List.duplicate(0.0, 32), width: 200, height: 40)

      assert lit?(scope, 100, 20) or lit?(scope, 100, 19)
    end

    test "a full swing reaches the top and the bottom" do
      samples = for i <- 0..63, do: :math.sin(i / 63 * 2 * :math.pi())
      scope = Paint.scope(samples, width: 200, height: 40)

      assert Enum.any?(0..5, &any_lit_row?(scope, &1)), "the trace should reach the top"
      assert Enum.any?(34..39, &any_lit_row?(scope, &1)), "and the bottom"
    end

    test "samples outside the range are brought back in rather than drawn off the raster" do
      assert %Raster{} = Paint.scope([-9.0, 9.0, -9.0], width: 100, height: 20)
    end

    test "no samples still draws the zero line" do
      scope = Paint.scope([], width: 100, height: 20)

      assert lit?(scope, 50, 10) or lit?(scope, 50, 9)
    end

    test "a single sample does not divide by no width" do
      assert %Raster{} = Paint.scope([0.5], width: 100, height: 20)
    end
  end

  defp any_lit_row?(raster, y) do
    Enum.any?(0..(raster.width - 1), &lit?(raster, &1, y))
  end

  defp count_lit(raster) do
    for x <- 0..(raster.width - 1), y <- 0..(raster.height - 1), lit?(raster, x, y), reduce: 0 do
      count -> count + 1
    end
  end
end
