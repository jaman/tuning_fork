defmodule KinoTuningFork.PlayerTest do
  @moduledoc """
  Runs `test/js/player_test.mjs` against `KinoTuningFork.Player.js/0` under `node`; skipped
  when `node` is not installed.
  """

  use ExUnit.Case, async: true

  alias KinoTuningFork.Player

  @harness Path.expand("../js/player_test.mjs", __DIR__)

  describe "the player, run" do
    @tag :tmp_dir
    test "it schedules chunks back to back, drops them while stopped, and cuts on stop", %{
      tmp_dir: dir
    } do
      case System.find_executable("node") do
        nil ->
          IO.puts(:stderr, "\n  * skipped player_test.mjs — node is not installed\n")

        node ->
          File.write!(
            Path.join(dir, "player.mjs"),
            Player.js() <> "\nexport { tuningForkPlayer };\n"
          )

          File.cp!(@harness, Path.join(dir, "test.mjs"))

          {output, status} = System.cmd(node, ["test.mjs"], cd: dir, stderr_to_stdout: true)

          assert status == 0, output
          assert output =~ "as expected"
      end
    end
  end
end
