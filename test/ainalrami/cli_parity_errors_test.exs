defmodule Ainalrami.CLIParityErrorsTest do
  @moduledoc """
  What the CLI says to a flag or record it cannot honour (a clear message,
  exit 1, nothing paired), what it says when it pairs by a rule that is not
  FIDE's, and that it says nothing new when none of this is used.

  The answers themselves are `cli_library_equivalence_test.exs`'s.
  """
  # Not async: `capture_io(:stderr, ...)` is VM-wide.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Ainalrami.{CLI, Generator, TeamGenerator, RoundRobinGenerator, Trf}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ainalrami_errors_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {text, _} = Generator.generate(seed: 9, players: 11, rounds: 3)
    swiss = Path.join(dir, "swiss.trf")
    File.write!(swiss, text)

    {team_text, _} = TeamGenerator.generate(system: :swiss, seed: 4, teams: 8, rounds: 3)
    team = Path.join(dir, "team.trf")
    File.write!(team, team_text)

    {rr_text, _} = RoundRobinGenerator.generate(seed: 4, players: 6, rounds: 2)
    rr = Path.join(dir, "rr.trf")
    File.write!(rr, rr_text)

    {:ok, dir: dir, swiss: swiss, text: text, team: team, rr: rr}
  end

  # `{stdout, stderr, exit code}`.
  defp cli(args) do
    ref = make_ref()

    out =
      capture_io(fn ->
        err = capture_io(:stderr, fn -> Process.put({ref, :code}, CLI.run(args)) end)
        Process.put({ref, :err}, err)
      end)

    {out, Process.get({ref, :err}), Process.get({ref, :code})}
  end

  describe "a value the flag cannot take" do
    for {flags, message} <- [
          {["-p", "--rounds=0"], "--rounds must be at least 1"},
          {["-p", "--rounds=nine"], "--rounds takes a whole number"},
          {["-p", "--initial-colour=green"], "unknown initial colour \"green\""},
          {["-p", "--points=3,1"], "--points takes WIN,DRAW,LOSS"},
          {["-p", "--points=win:x"], "--points takes WIN,DRAW,LOSS"},
          {["-p", "--points=goals:3"], "--points takes WIN,DRAW,LOSS"},
          {["-p", "--points=3,1,-1"], "--points takes WIN,DRAW,LOSS"},
          {["-p", "--forbidden=4"], "--forbidden takes groups of two or more"},
          {["-p", "--forbidden=1,x"], "--forbidden takes groups of two or more"},
          {["-p", "--forbidden=1,2@5-3"], "--forbidden takes groups of two or more"},
          {["-p", "--forbidden=1,1"], "--forbidden takes groups of two or more"},
          {["-p", "--forbidden=1,99"], "--forbidden names 99, which is not a starting rank"},
          {["-p", "--soft-pairs=4"], "--soft-pairs takes groups of two or more"},
          {["-p", "--soft-pairs=1,2@x"], "--soft-pairs takes groups of two or more"},
          {["-p", "--soft-position=weak"], "--soft-position needs --soft-pairs"},
          {["-p", "--bye-exclude=x"], "--bye-exclude takes starting ranks"},
          {["-p", "--bye-exclude=3@"], "--bye-exclude takes starting ranks"},
          {["-p", "--bye-exclude=3@4-2"], "--bye-exclude takes starting ranks"},
          {["-p", "--acceleration=bakku"], "unknown acceleration \"bakku\""},
          {["-p", "--acceleration=random"], "--acceleration=random is the generator's"},
          {["-p", "--baku-group-a=4"], "--baku-group-a needs --acceleration=baku"},
          {["-p", "--acceleration=baku", "--baku-group-a=0"],
           "--baku-group-a must be at least 1"},
          {["-p", "--acceleration=baku", "--baku-group-a=99"],
           "--baku-group-a names 99, which is not a starting rank"},
          {["-p", "--acceleration=baku", "--virtual-points=1:1"], "are alternatives - give one"},
          {["-p", "--virtual-points=1"], "--virtual-points takes RANKS:POINTS"},
          {["-p", "--virtual-points=1:x"], "--virtual-points takes RANKS:POINTS"},
          {["-p", "--virtual-points=1:-1"], "--virtual-points takes RANKS:POINTS"},
          {["-p", "--virtual-points=1:1/1:0.5"], "--virtual-points names 1 twice"},
          {["-p", "--virtual-points=99:1"], "--virtual-points names 99"},
          {["-p", "--half-bye=x"], "--half-bye takes numbers separated by commas"},
          {["-p", "--zero-bye=99"], "a bye for 99, which is not a starting rank"},
          {["-p", "--half-bye=3", "--zero-bye=3"], "two byes for starting rank 3"},
          {["-p", "--absent-teams=2"], "--absent-teams names team 2"},
          {["-x", "--judge=1-2"], "--judge has to seat the players of the round exactly once"},
          {["-x", "--judge=1+2"], "--judge takes a whole round"},
          {["-x", "--judge=1-1"], "--judge takes a whole round"},
          {["-s", "--tie-breaks=BH,NOPE"], "--tie-breaks:"},
          {["-s", "--tie-breaks=BH", "--cap-rounds=some"], "unknown --cap-rounds \"some\""},
          {["-p", "--forbidden"], "--forbidden takes its value with an equals sign"},
          {["-p", "--bye-exclude", "3"], "--bye-exclude takes its value with an equals sign"},
          {["-p", "--cascade-order=yes"], "unknown option --cascade-order"}
        ] do
      test "#{Enum.join(flags, " ")}", %{swiss: swiss} do
        {out, err, code} = cli([swiss | unquote(flags)])
        assert code == 1
        assert err =~ unquote(message)
        # Nothing was paired, ranked or explained.
        assert out =~ "Usage:"
        refute out =~ ~r/^\d+ \d+\r$/m
      end
    end

    test "--acceleration=baku without a round count asks for --rounds", %{dir: dir, text: text} do
      path = Path.join(dir, "norounds.trf")

      File.write!(
        path,
        text
        |> String.split("\r\n")
        |> Enum.reject(&(String.starts_with?(&1, "142") or String.starts_with?(&1, "XXR")))
        |> Enum.join("\r\n")
      )

      {_out, err, code} = cli([path, "-p", "--acceleration=baku"])
      assert code == 1
      assert err =~ "needs the tournament's round count"
      assert {_, _, 0} = cli([path, "-p", "-q", "--acceleration=baku", "--rounds=7"])
    end

    test "--acceleration and --virtual-points on a file that already has XXA", %{dir: dir} do
      {text, _} = Generator.generate(seed: 3, players: 10, rounds: 3, acceleration: :baku)
      path = Path.join(dir, "xxa.trf")
      File.write!(path, text)

      for flag <- ["--acceleration=baku", "--virtual-points=1:1"] do
        {_out, err, code} = cli([path, "-p", flag])
        assert code == 1
        assert err =~ "already carries virtual points"
      end
    end

    test "a bye for a player who already has the round recorded", %{dir: dir, text: text} do
      path = Path.join(dir, "bye.trf")
      File.write!(path, text)
      assert {_, _, 0} = cli([path, "-p", "-q", "--half-bye=3"])

      parsed = Trf.parse(text)

      players =
        Enum.map(parsed.players, fn p ->
          if p.rank == 3,
            do: %{
              p
              | games: p.games ++ [%{opponent_rank: nil, colour: nil, result: "H"}],
                points: p.points + 0.5
            },
            else: p
        end)

      File.write!(path, Trf.serialize(%{parsed | players: players}))
      {_out, err, code} = cli([path, "-p", "--zero-bye=3"])
      assert code == 1
      assert err =~ "starting rank 3 already has an entry for round 4"
    end
  end

  describe "a flag in a mode that does not have it" do
    for {flags, message} <- [
          {["-c", "--cascade-order"], "--cascade-order is for -p, not -c"},
          {["-c", "--bye-exclude=3"], "--bye-exclude is for -p, -x, not -c"},
          {["-c", "--half-bye=3"], "--half-bye is for -p, -x, not -c"},
          {["-p", "--judge=1-2"], "--judge is for -x, not -p"},
          {["-p", "--bye-alternatives"], "--bye-alternatives is for -x, not -p"},
          {["-p", "--float-alternatives"], "--float-alternatives is for -x, not -p"},
          {["-p", "--alternative-pairs"], "--alternative-pairs is for -x, not -p"},
          {["-p", "--cap-rounds=played"], "--cap-rounds is for -c, -s, not -p"},
          {["-p", "--explain-limit=5"], "--explain-limit is for -x, not -p"},
          {["-s", "--forbidden=1,2"], "--forbidden is for -p, -x, -c, not -s"},
          {["-s", "--bye-want=3"], "--bye-want is for -p, -x, not -s"},
          {["-s", "--soft-pairs=1,2"], "--soft-pairs is for -p, -x, not -s"},
          {["-c", "--bye-want=3"], "apply to -p and -x only"},
          {["-c", "--soft-pairs=1,2"], "--soft-pairs applies to -p and -x only"}
        ] do
      test "#{Enum.join(flags, " ")}", %{swiss: swiss} do
        {_out, err, code} = cli([swiss | unquote(flags)])
        assert code == 1
        assert err =~ unquote(message)
      end
    end

    test "-g refuses the pairing flags", %{dir: dir} do
      out = Path.join(dir, "never.trf")

      for flag <- ~w(--forbidden=1,2 --bye-exclude=3 --points=3,1,0 --virtual-points=1:1
                     --half-bye=2 --cascade-order --judge=1-2 --cap-rounds=played) do
        {_out, err, code} = cli(["-g", out, "--seed=1", flag])
        assert code == 1, flag
        assert err =~ "not -g", flag
        refute File.exists?(out)
      end
    end
  end

  describe "a flag for another kind of file" do
    test "team flags on an individual file", %{swiss: swiss} do
      for mode <- ["-p", "-x", "-c"],
          flag <- ~w(--team-type=b --score=gp --secondary=no --max-upfloater-sets=5) do
        {_out, err, code} = cli([swiss, mode, flag])
        assert code == 1, "#{mode} #{flag}"
        assert err =~ "is for a team", "#{mode} #{flag}"
      end
    end

    test "individual flags on a team file", %{team: team} do
      for mode <- ["-p", "-x", "-c"],
          flag <- ~w(--forbidden=1,2 --virtual-points=1:1) do
        {_out, err, code} = cli([team, mode, flag])
        assert code == 1, "#{mode} #{flag}"
        assert err =~ "is for an individual tournament, not a team event", "#{mode} #{flag}"
      end

      for flag <- ~w(--bye-exclude=1 --cascade-order) do
        {_out, err, code} = cli([team, "-p", flag])
        assert code == 1
        assert err =~ "is for an individual tournament, not a team event"
      end

      {_out, err, code} = cli([team, "-p", "--max-upfloater-sets=0"])
      assert code == 1
      assert err =~ "--max-upfloater-sets must be at least 1"
    end

    test "neither kind's on a round robin", %{rr: rr} do
      for flag <- ~w(--forbidden=1,2 --bye-exclude=1 --half-bye=2 --team-type=b --cascade-order
                     --acceleration=baku) do
        {_out, err, code} = cli([rr, "-p", flag])
        assert code == 1, flag
        assert err =~ "is not for a round robin", flag
      end
    end

    test "XXO soft pairs and byes on a team file or a round robin are refused, not ignored", %{
      dir: dir,
      team: team,
      rr: rr
    } do
      for {source, name} <- [{team, "t"}, {rr, "r"}],
          line <- ["XXO soft-pairs 1 2", "XXO bye-avoid 1"] do
        path = Path.join(dir, "org_#{name}.trf")
        File.write!(path, File.read!(source) <> line <> "\r\n")

        for mode <- ["-p", "-x", "-c"] do
          {_out, err, code} = cli([path, mode])
          assert code == 1, "#{name} #{mode} #{line}"
          assert err =~ "XXO soft-pair and bye records are for", "#{name} #{mode} #{line}"
        end
      end
    end
  end

  describe "a record the file gets wrong" do
    for {line, message} <- [
          {"XXO", "XXO line says nothing"},
          {"XXO soft-pairs", "XXO does not have \"soft-pairs\""},
          {"XXO soft 1 2", "XXO does not have \"soft\""},
          {"XXO soft-pairs 4", "XXO soft-pairs takes two or more starting ranks"},
          {"XXO soft-pairs 1 x", "XXO soft-pairs takes two or more starting ranks"},
          {"XXO soft-pairs 1 2 @5-3", "XXO soft-pairs takes two or more starting ranks"},
          {"XXO soft-position medium", "XXO soft-position takes strong or weak"},
          {"XXO soft-pairs 1 99", "XXO names 99, which is not a starting rank"},
          {"XXO bye-maybe 3", "XXO does not have \"bye-maybe\""},
          {"XXO bye-avoid 3@x", "XXO bye-avoid takes starting ranks"},
          {"XXO bye-exclude 99", "XXO names 99, which is not a starting rank"},
          {"XXO bye-want-soft 99@2", "XXO names 99, which is not a starting rank"},
          {"XXO round-ratings 3", "XXO round-ratings takes a starting rank"},
          {"XXO round-ratings 3 21x0", "XXO round-ratings takes a starting rank"},
          {"XXO round-ratings 99 2100", "XXO names 99, which is not a starting rank"},
          {"XXO round-ratings 3 2100\r\nXXO round-ratings 3 2200",
           "two XXO round-ratings lines for starting rank 3"}
        ] do
      test inspect(line), %{dir: dir, text: text} do
        path = Path.join(dir, "bad_record.trf")
        File.write!(path, text <> unquote(line) <> "\r\n")

        for mode <- ["-p", "-x", "-c", "-s"] do
          {out, err, code} = cli([path, mode, "-q"])
          assert code == 1
          assert err =~ "invalid TRF file"
          assert err =~ unquote(message)
          assert out == ""
        end

        assert_raise Trf.ValidationError, fn -> Trf.parse(File.read!(path)) end
      end
    end
  end

  describe "not a pure FIDE pairing" do
    @warning "not a pure FIDE"

    test "nothing is said for a file and a command line with none of it", %{swiss: swiss} do
      for args <- [
            ["-p", "-q"],
            ["-x", "-q"],
            ["-c", "-q"],
            ["-p", "-q", "--rounds=5", "--initial-colour=black", "--points=3,1,0"],
            ["-p", "-q", "--forbidden=1,2", "--half-bye=3", "--cascade-order"],
            ["-p", "-q", "--acceleration=baku", "--rounds=7"]
          ] do
        {_out, err, code} = cli([swiss | args])
        assert code == 0, err
        refute err =~ @warning
        refute err =~ "FIDE checker"
      end
    end

    for {flag, words} <- [
          {"--bye-exclude=3", "bye exclusions are an organiser's rule, not FIDE's"},
          {"--bye-avoid=3", "bye preferences are an organiser's rule, not FIDE's"},
          {"--bye-want-soft=3", "bye preferences are an organiser's rule, not FIDE's"},
          {"--soft-pairs=1,2", "soft pairs are an organiser's wish, not FIDE's"},
          {"--soft-pairs=1,2@9", "soft pairs are an organiser's wish, not FIDE's"},
          {"--virtual-points=1:1,1,1,1", "an organiser's acceleration, not C.04.7's Baku"}
        ] do
      test "#{flag} says so on stderr, for -p and for -x", %{swiss: swiss} do
        for mode <- ["-p", "-x"] do
          {out, err, code} = cli([swiss, mode, "-q", unquote(flag)])
          assert code == 0, err
          assert err =~ unquote(words)
          assert err =~ @warning
          refute out =~ "warning"
        end
      end
    end

    for {line, words} <- [
          {"XXO bye-exclude 3", "bye exclusions are an organiser's rule, not FIDE's"},
          {"XXO bye-avoid-soft 3", "bye preferences are an organiser's rule, not FIDE's"},
          {"XXO soft-pairs 1 2", "soft pairs are an organiser's wish, not FIDE's"}
        ] do
      test "#{line} in the file says so too, and -c says what it replays with", %{
        dir: dir,
        text: text
      } do
        path = Path.join(dir, "organiser.trf")
        File.write!(path, text <> unquote(line) <> "\r\n")

        for mode <- ["-p", "-x"] do
          {_out, err, code} = cli([path, mode, "-q"])
          assert code == 0, err
          assert err =~ unquote(words)
        end

        {_out, err, _code} = cli([path, "-c", "-q"])
        assert err =~ "the file carries the organiser's own rules"
        assert err =~ "not a pure FIDE check"
      end
    end

    test "the trace names the file's organiser records", %{dir: dir, text: text} do
      path = Path.join(dir, "trace.trf")

      File.write!(
        path,
        text <>
          "XXO soft-pairs 1 2 @4-5\r\nXXO soft-position weak\r\nXXO bye-exclude 3@4\r\n" <>
          "XXO bye-want-soft 5\r\n"
      )

      {out, _err, 0} = cli([path, "-p"])
      assert out =~ "soft pair (XXO): #1 / #2 (rounds 4-5)"
      assert out =~ "bye exclusion (XXO): #3@4"
      assert out =~ "bye preference (XXO): #5 want_soft"
    end
  end

  describe "-s" do
    test "a file with no tie-break list needs --tie-breaks=", %{swiss: swiss} do
      {_out, err, code} = cli([swiss, "-s"])
      assert code == 1
      assert err =~ "no tie-break list"

      {out, _err, code} = cli([swiss, "-s", "-q", "--tie-breaks=BH"])
      assert code == 0
      assert [header | rows] = String.split(out, "\r\n", trim: true)
      assert header == "RANK ID PTS BH"
      assert length(rows) == 11
    end

    test "writes to a file when given one, and a list starting with a score is the whole order",
         %{swiss: swiss, dir: dir} do
      target = Path.join(dir, "standings.txt")
      {out, _err, 0} = cli([swiss, "-s", target, "-q", "--tie-breaks=PTS,SB,TPN"])
      assert out == ""
      assert "RANK ID PTS SB TPN\r\n" <> _ = File.read!(target)
    end

    test "the help lists every new flag and record" do
      {out, _err, 0} = cli(["--help"])

      for word <- ~w(--rounds=N --initial-colour=white|black --points=3,1,0 --forbidden=
                     --acceleration=baku --baku-group-a=N --virtual-points= --half-bye=
                     --zero-bye= --full-bye= --cascade-order --bye-exclude=RANKS --judge=
                     --bye-alternatives --float-alternatives --alternative-pairs
                     --absent-teams= --team-type=a|b|none
                     --max-upfloater-sets=N --explain-limit=N --tie-breaks=BH,SB
                     --cap-rounds=played|announced XXO) do
        assert out =~ word, word
      end
    end
  end
end
