# The team CLI's proof run: generated team events through the CLI itself.
#
#   mix run tools/team_cli_corpus.exs SWISS_COUNT RR_COUNT [FIRST_SEED [INDIVIDUAL_RR_COUNT]]
#
# INDIVIDUAL_RR_COUNT adds individual round robins
# (`Ainalrami.RoundRobinGenerator`): -c, and -p on every round of the file
# cut back to before it, against the Berger table's boards and free player.
#
# For every seed, `Ainalrami.TeamGenerator.run/1` makes an event (a team
# Swiss paired round by round by `Ainalrami.TeamPairing` called directly, or
# a team round robin by the Berger tables), and then:
#
#   1. `ainalrami file -c` must exit 0 - every round matches, and the final
#      ranks follow the file's tie-break list when it has one;
#   2. for every round k, the file cut back to what it held before round k
#      was paired (rounds 1..k-1, plus round k's announced absences - the
#      zero-point byes the generator recorded before pairing, which TRF26
#      writes as `240` records - and round k's `300` lineups) is given to
#      `ainalrami cut.trf -p out --lineups --boards=B`, and the output must
#      be exactly the generator's round k: the same matches with the same
#      colours, the same bye (or free round), and the same players on every
#      board.
#
# The options left out are drawn from each seed, so the corpus covers every
# axis the generator has. Environment: CORPUS_CONCURRENCY (default 4),
# CORPUS_DIR (scratch files, default tmp/team_cli_corpus),
# CORPUS_BAKU=1 (every team Swiss Baku-accelerated).
#
# Prints one line per failure and a summary; exits 1 on any failure.

alias Ainalrami.{CLI, TeamGenerator, Trf}

defmodule TeamCliCorpus do
  alias Ainalrami.{CLI, TeamGenerator, Trf}

  @pre_recorded ~w(Z H F)

  def run_one(:individual_rr, seed, dir) do
    g = Ainalrami.RoundRobinGenerator.run(seed: seed)
    base = Path.join(dir, "individual_rr_#{seed}")
    full = base <> ".trf"
    File.write!(full, g.text)
    check = CLI.run([full, "-c", "-q"])
    parsed = Trf.parse(g.text)
    failures = if check == 0, do: [], else: ["individual_rr seed #{seed}: -c exited #{check}"]

    failures =
      Enum.reduce(1..g.rounds//1, failures, fn k, acc ->
        cut = base <> "_r#{k}.trf"
        out = base <> "_r#{k}.out"
        File.write!(cut, Trf.serialize(truncate(parsed, k), dialect: :trf26))
        code = CLI.run([cut, "-p", out, "-q"])
        expected = g.pairings[k]

        expected_lines =
          Enum.map(expected.boards, fn {w, b} -> "#{w} #{b}" end) ++
            if(expected.free, do: ["#{expected.free} 0"], else: [])

        result =
          cond do
            code != 0 ->
              ["individual_rr seed #{seed} round #{k}: -p exited #{code}"]

            output_lines(File.read!(out)) != expected_lines ->
              ["individual_rr seed #{seed} round #{k}: boards differ"]

            true ->
              []
          end

        File.rm(cut)
        File.rm(out)
        acc ++ result
      end)

    if failures == [], do: File.rm(full)
    {g.rounds, failures}
  end

  def run_one(system, seed, dir) do
    # CORPUS_BAKU=1: every team Swiss accelerated (C.04.7), its 250s
    # written, so -c and each cut file's -p pair on the virtual points.
    baku = system == :swiss and System.get_env("CORPUS_BAKU") == "1"
    g = TeamGenerator.run([seed: seed, system: system] ++ if(baku, do: [baku: true], else: []))
    base = Path.join(dir, "#{system}_#{seed}")
    full = base <> ".trf"
    File.write!(full, g.text)

    check = CLI.run([full, "-c", "-q"])
    parsed = Trf.parse(g.text)

    failures =
      if check == 0, do: [], else: ["#{system} seed #{seed}: -c exited #{check}"]

    failures =
      Enum.reduce(1..g.rounds//1, failures, fn k, acc ->
        cut = base <> "_r#{k}.trf"
        out = base <> "_r#{k}.out"
        absent = g.pairings[k].absent

        File.write!(
          cut,
          Trf.serialize(truncate(parsed, k, team_players(parsed, absent)), dialect: :trf26)
        )

        code = CLI.run([cut, "-p", out, "--lineups", "--boards=#{g.boards}", "-q"])

        result =
          cond do
            code != 0 ->
              ["#{system} seed #{seed} round #{k}: -p exited #{code}"]

            true ->
              compare(File.read!(out), g.pairings[k], g.boards, system, seed, k)
          end

        File.rm(cut)
        File.rm(out)
        acc ++ result
      end)

    if failures == [], do: File.rm(full)
    {g.rounds, failures}
  end

  # The board lines of a JaVaFo-style pairing list, the count line dropped.
  defp output_lines(text), do: text |> String.split(~r/\r?\n/, trim: true) |> tl()

  # The players of the teams named.
  def team_players(parsed, teams) do
    parsed.teams
    |> Enum.with_index(1)
    |> Enum.filter(fn {t, i} -> (Map.get(t, :number) || i) in teams end)
    |> Enum.flat_map(fn {t, _} -> t.player_ranks end)
  end

  # What the file held before round k was paired. `absent` are the players
  # of the teams that announced they would sit round k out: in a round
  # robin such a team is paired all the same and forfeits, and since 0.53.0
  # that forfeit is written on its players' lines over the announcement -
  # so their `Z` is put back, as the file had it before the pairing.
  def truncate(parsed, k, absent \\ []) do
    players =
      Enum.map(parsed.players, fn p ->
        earlier = Enum.take(p.games, k - 1)

        games =
          case Enum.at(p.games, k - 1) do
            %{opponent_rank: nil, result: r} = g when r in @pre_recorded ->
              earlier ++ [g]

            %{} = g ->
              if p.rank in absent,
                do: earlier ++ [%{g | opponent_rank: nil, colour: nil, result: "Z"}],
                else: earlier

            _ ->
              earlier
          end

        %{p | games: games, points: games |> Enum.map(&points/1) |> Enum.sum()}
      end)

    t = parsed.tournament

    tournament =
      t
      |> Map.delete(:standings_order)
      |> Map.delete(:tie_breaks)
      |> Map.delete(:byes)
      |> update(:forfeited_matches, &Enum.filter(&1, fn f -> f.round < k end))
      |> update(:board_orders, &Enum.filter(&1, fn o -> o.round <= k end))
      |> update(:team_pab, &%{&1 | teams: Enum.take(&1.teams, k - 1)})

    teams = Enum.map(parsed.teams, &Map.merge(&1, %{final_rank: nil}))
    %{parsed | players: players, tournament: tournament, teams: teams}
  end

  defp update(map, key, fun) do
    case Map.get(map, key) do
      nil -> map
      value -> map |> Map.put(key, fun.(value)) |> drop_empty(key)
    end
  end

  defp drop_empty(map, key) do
    if map[key] == [], do: Map.delete(map, key), else: map
  end

  defp points(%{result: r}) when r in ["1", "+", "U", "F"], do: 1.0
  defp points(%{result: r}) when r in ["=", "H"], do: 0.5
  defp points(_), do: 0.0

  def compare(text, expected, boards, system, seed, k) do
    lines = text |> String.split("\r\n", trim: true)
    [count | rest] = lines
    count = String.to_integer(count)
    {team_lines, [_board_count | board_lines]} = Enum.split(rest, count)

    pairs =
      Enum.map(team_lines, fn l ->
        [a, b] = l |> String.split() |> Enum.map(&String.to_integer/1)
        {a, b}
      end)

    {byes, matches} = Enum.split_with(pairs, fn {_a, b} -> b == 0 end)
    bye = Enum.map(byes, &elem(&1, 0))

    expected_bye = List.wrap(expected.bye || expected[:free])

    boards_out =
      board_lines
      |> Enum.map(fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)

    expected_boards =
      for {{w, b}, match} <- Enum.with_index(matches, 1),
          {{x, y}, board} <-
            Enum.with_index(
              Enum.zip(padded(expected.lineups[w], boards), padded(expected.lineups[b], boards)),
              1
            ) do
        if rem(board, 2) == 1, do: [match, board, x, y], else: [match, board, y, x]
      end

    tag = "#{system} seed #{seed} round #{k}"

    cond do
      Enum.sort(matches) != Enum.sort(expected.matches) ->
        [
          "#{tag}: matches #{inspect(Enum.sort(matches))} vs generator #{inspect(Enum.sort(expected.matches))}"
        ]

      bye != expected_bye ->
        ["#{tag}: bye #{inspect(bye)} vs generator #{inspect(expected_bye)}"]

      boards_out != expected_boards ->
        [
          "#{tag}: board lines differ: #{inspect(Enum.take(boards_out -- expected_boards, 3))} vs #{inspect(Enum.take(expected_boards -- boards_out, 3))}"
        ]

      true ->
        []
    end
  end

  defp padded(nil, boards), do: List.duplicate(0, boards)

  defp padded(list, boards) do
    list = Enum.map(list, &(&1 || 0))
    list ++ List.duplicate(0, boards - length(list))
  end
end

[swiss, rr | rest] = System.argv()
individual_rr = rest |> Enum.at(1, "0") |> String.to_integer()
swiss = String.to_integer(swiss)
rr = String.to_integer(rr)
first = String.to_integer(List.first(rest) || "1")
dir = System.get_env("CORPUS_DIR", "tmp/team_cli_corpus")
File.mkdir_p!(dir)
concurrency = String.to_integer(System.get_env("CORPUS_CONCURRENCY", "4"))

jobs =
  Enum.map(first..(first + swiss - 1)//1, &{:swiss, &1}) ++
    Enum.map(first..(first + rr - 1)//1, &{:round_robin, &1}) ++
    Enum.map(first..(first + individual_rr - 1)//1, &{:individual_rr, &1})

started = System.monotonic_time(:millisecond)

{events, rounds, failures} =
  jobs
  |> Task.async_stream(
    fn {system, seed} ->
      try do
        TeamCliCorpus.run_one(system, seed, dir)
      rescue
        e ->
          {0,
           ["#{system} seed #{seed}: crashed - #{Exception.format(:error, e, __STACKTRACE__)}"]}
      end
    end,
    max_concurrency: concurrency,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.reduce({0, 0, []}, fn {:ok, {r, f}}, {e, rounds, fails} ->
    Enum.each(f, &IO.puts("FAIL " <> &1))
    {e + 1, rounds + r, fails ++ f}
  end)

seconds = div(System.monotonic_time(:millisecond) - started, 1000)

IO.puts(
  "team CLI corpus: #{swiss} team Swiss + #{rr} team round robin + #{individual_rr} " <>
    "individual round robin events (seeds #{first}..), " <>
    "#{events} run, #{rounds} rounds re-paired by -p, #{length(failures)} failure(s), #{seconds} s"
)

if failures != [], do: System.halt(1)
