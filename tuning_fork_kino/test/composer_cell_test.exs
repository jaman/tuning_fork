defmodule KinoTuningFork.ComposerCellTest do
  @moduledoc """
  Tests `KinoTuningFork.ComposerCell`'s opening state, its browser round trip, and the source
  it writes.
  """

  use ExUnit.Case, async: true

  alias Kino.JS.Live.Context
  alias KinoTuningFork.ComposerCell
  alias TuningFork.Composer
  alias TuningFork.Composer.Json

  defp ctx(attrs \\ %{}) do
    {:ok, ctx} = ComposerCell.init(attrs, Context.new())

    put_in(ctx.__private__[:ref], make_ref())
  end

  describe "opening" do
    test "a saved cell opens on what was saved" do
      saved = Composer.demo() |> Composer.set(:bpm, 132) |> Composer.toggle_mute(0)
      reopened = saved |> Json.to_map() |> ctx() |> Map.fetch!(:assigns) |> Map.fetch!(:project)

      assert reopened == saved
    end
  end

  describe "the boundary" do
    test "a field the browser sends reaches the composition" do
      {:noreply, ctx} =
        ComposerCell.handle_event("update_field", %{"field" => "bpm", "value" => 140}, ctx())

      assert ctx.assigns.project.bpm == 140
    end

    test "play loops the grid on a stage of the cell's own, repeat by repeat, and stop ends it" do
      {:noreply, playing} = ComposerCell.handle_event("play", %{}, ctx())

      assert playing.assigns.playing
      assert is_pid(playing.assigns.stage)
      assert %{grid: %{rounds: _rounds}} = TuningFork.Stage.loops(playing.assigns.stage)

      {:noreply, edited} =
        ComposerCell.handle_event("update_field", %{"field" => "bpm", "value" => 140}, playing)

      assert edited.assigns.playing
      assert ComposerCell.current(edited).bpm == 140

      {:noreply, stopped} = ComposerCell.handle_event("stop", %{}, edited)
      refute stopped.assigns.playing
      Process.sleep(50)
      assert TuningFork.Stage.loops(stopped.assigns.stage) == %{}
    end

    test "tracks the browser sends reach the composition" do
      start = ctx()
      tracks = start |> ComposerCell.to_attrs() |> Map.fetch!("tracks")
      edited = List.update_at(tracks, 0, &Map.put(&1, "muted", true))

      {:noreply, ctx} =
        ComposerCell.handle_event("update_tracks", %{"tracks" => edited}, start)

      assert Composer.track(ctx.assigns.project, 0).muted
    end

    test "a field the composer does not have changes nothing, least of all a different one" do
      start = ctx()

      {:noreply, ctx} =
        ComposerCell.handle_event("update_field", %{"field" => "wat", "value" => 1}, start)

      assert %Composer{} = ctx.assigns.project
      assert ctx.assigns.project == start.assigns.project
      assert ctx.assigns.project.name == start.assigns.project.name
    end
  end

  describe "what it writes" do
    test "it parses, and runs as far as the line that needs Kino" do
      source = ComposerCell.to_source(ComposerCell.to_attrs(ctx()))

      assert {:ok, _ast} = Code.string_to_quoted(source)

      {wav, _binding} =
        source |> String.replace("|> Kino.Audio.new(:wav)", "") |> Code.eval_string()

      assert {:ok, pcm, 44_100, 2} = TuningFork.Wav.decode(wav)
      assert TuningFork.Mixer.peak(pcm) > 1_000
    end
  end
end
