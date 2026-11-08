defmodule AinalramiVerify.TeamCheckTest do
  use ExUnit.Case, async: true

  alias AinalramiVerify.{Certificate, Engine, TeamCheck, TeamWalk}

  defp certified(input, round) do
    text = JSON.encode!(input)
    {:ok, cert} = Engine.team_certify(input, round, Certificate.sha256(text))
    {text, cert |> JSON.encode!() |> JSON.decode!()}
  end

  defp events(seeds, opts) do
    for seed <- seeds,
        r <-
          TeamWalk.rounds(
            [teams: 5 + rem(seed * 7, 26), rounds: 3 + rem(seed, 6), seed: seed] ++ opts
          ),
        do: r
  end

  test "the engine's team rounds certify and check (match points)" do
    rounds = events(1..40, [])
    assert length(rounds) > 150

    for {input, round} <- rounds do
      {text, cert} = certified(input, round)

      assert TeamCheck.check(text, cert, Engine.team_output(round)) == :ok,
             inspect(input["round"])
    end
  end

  test "game points primary, teams kept apart" do
    for {input, round} <- events(41..70, score_mode: "game_points", keep_apart: true) do
      {text, cert} = certified(input, round)
      assert TeamCheck.check(text, cert) == :ok
    end
  end

  describe "the checker is not a rubber stamp" do
    setup do
      [{input, round} | _] =
        events(200..260, [])
        |> Enum.filter(fn {i, r} -> length(r.pairs) >= 3 and i["round"] >= 3 end)

      {text, cert} = certified(input, round)
      %{input: input, text: text, cert: cert, round: round}
    end

    test "another input", %{text: text, cert: cert} do
      assert {:error, "the input is not the one certified" <> _} =
               TeamCheck.check(text <> " ", cert)
    end

    test "two matches re-partnered", %{text: text, cert: cert} do
      [[a, b], [c, d] | rest] = cert["pairs"]
      bad = %{cert | "pairs" => [[a, d], [c, b] | rest]}
      assert {:error, _} = TeamCheck.check(text, bad)
    end

    test "colours turned round", %{text: text, cert: cert} do
      [[a, b] | rest] = cert["pairs"]

      assert {:error, "Article 4" <> _} =
               TeamCheck.check(text, %{cert | "pairs" => [[b, a] | rest]})
    end

    test "a dual tampered with", %{text: text, cert: cert} do
      [first | others] = cert["brackets"]
      tops = first["tops"]

      bumped =
        case tops["duals"] do
          [[v, y] | more] -> [[v, Integer.to_string(String.to_integer(y) + 1)] | more]
          [] -> [[hd(first["residents"]), "1"]]
        end

      bad = %{cert | "brackets" => [%{first | "tops" => %{tops | "duals" => bumped}} | others]}
      assert {:error, _} = TeamCheck.check(text, bad)
    end

    test "another pairing list", %{text: text, cert: cert, round: round} do
      [p, q | rest] = round.pairs

      other = %{
        round
        | pairs: [%{white: p.white, black: q.black}, %{white: q.white, black: p.black} | rest]
      }

      assert {:error, "the pairing list is not the certified round"} =
               TeamCheck.check(text, cert, Engine.team_output(other))
    end
  end

  test "every other legal re-partnering of a bracket is refused by certify" do
    for {input, round} <- events(300..330, []), length(round.pairs) >= 2 do
      [p, q | rest] = round.pairs

      other = %{
        round
        | pairs: [%{white: p.white, black: q.black}, %{white: q.white, black: p.black} | rest]
      }

      text = JSON.encode!(input)
      assert {:error, _} = Engine.team_certify(input, other, Certificate.sha256(text))
    end
  end
end

defmodule AinalramiVerify.TeamCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AinalramiVerify.{CLI, TeamWalk}

  @moduletag :tmp_dir

  defp run(args) do
    me = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(me, {:code, CLI.run(args)}) end)
        send(me, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  test "team-pair, team-certify, team-check: OK; a tampered list: FAIL", %{tmp_dir: dir} do
    {input, _round} = [teams: 11, rounds: 5, seed: 9] |> TeamWalk.rounds() |> List.last()
    path = Path.join(dir, "input.json")
    File.write!(path, JSON.encode!(input))

    assert {0, list, _} = run(["team-pair", path])
    out = Path.join(dir, "output.txt")
    File.write!(out, list)

    cert = Path.join(dir, "cert.json")
    assert {0, _, _} = run(["team-certify", path, "--round", out, "-o", cert])
    assert {0, "OK\n", _} = run(["team-check", path, cert, out])

    [count, first | rest] = String.split(list, "\n", trim: true)
    [w, b] = String.split(first)
    File.write!(out, Enum.join([count, "#{b} #{w}" | rest], "\n") <> "\n")
    assert {1, "FAIL: " <> _, _} = run(["team-check", path, cert, out])
    assert {1, _, _} = run(["team-certify", path, "--round", out])
  end
end
