defmodule Ainalrami.TeamThreeWayTest do
  @moduledoc """
  C.04.6 team Swiss: Ainalrami, Gacrux and chesspairing asked the same
  question, every round.

  ## The three engines

    * **Ainalrami** - `Ainalrami.TeamPairing` through the path
      `ainalrami file -p` takes (`Ainalrami.Test.TeamThreeWay.ainalrami/1`).
    * **Gacrux** - Otto Milvang's TieBreakServer, `pairingchecker.py -p -dT
      -n R` with NO `-m`: the system, colour-preference type, primary score
      and whether the secondary score is used all come from the `192` code
      (`trf2json.py`'s table), as they do for the other two. Its team
      module (`pairingfideteam.py`) exists since July 2026.
    * **chesspairing** - Gert Nutterts' Go library, `chesspairing pair
      --team FILE` (`Ainalrami.Test.Chesspairing`), built from source.

  All three get the SAME file: the generated event cut before the round
  (`Ainalrami.Test.TeamThreeWay.file_for/2`, which also says why two
  records are rewritten and why the round's own absences are left out).

  ## What is compared

  Who plays whom, who has the pairing-allocated bye, and which team of each
  match is first - the team with White on board 1. Board colours are not
  compared separately: in C.04.6 they follow from that (1.6.1 and the
  board order), and none of the other two engines seats players. A round
  one engine cannot pair (C.04.6 3.3.3) is an answer too: two refusals
  agree.

  ## Every difference is classified

  For each engine pair:

    * `identical`;
    * `reading_c6_following`, `reading_c6_graded`, `reading_c6_both` - a
      difference involving Gacrux that Gacrux itself gives up once one of
      its [C6] (2.3.3) readings is replaced, in memory and nothing else
      changed, by Ainalrami's (tried in that order):
        - *following*: which scoregroup "the following scoregroup" is.
          Gacrux takes the score level one below the bracket's; when an
          earlier bracket took every team of that level as upfloaters it is
          empty and Gacrux skips [C6]. Ainalrami and chesspairing take the
          highest score level still to be paired below the residents.
        - *graded*: Gacrux reads [C6] pass/fail at the following
          scoregroup's parity minimum (`check_c6`, the first key of
          `select_upfloaters`); Ainalrami (`c6_excess/4`) and chesspairing
          (`lexswiss.selectUpfloaterSet`'s `c6UpfloaterCount`) read it
          graded - the fewest upfloaters that scoregroup will need.
        - *both* at once.
        - *float_forfeit*: whether a forfeited match (every board, or a
          `330`) against a team on another score makes a floater (1.5,
          read by [C7]). Gacrux counts played matches only
          (`tiebreak.compute_flt`), and so does chesspairing; Ainalrami
          counts every match.
        - *forfeit_gp*: where a forfeited match's game points come from.
          `Ainalrami.Test.TeamThreeWay.forfeit_points_in_rows/1` says how
          the two read it; this one is a rewritten file, not a script.
        - *combined*: *following*, *float_forfeit* and *forfeit_gp* at once.
      An `ac` difference takes the reading of the `ag` one when
      chesspairing gives exactly Gacrux's answer;
      The replacements are a VM-side script, `gacrux_readings.py`, not in
      this repository (`GACRUX_READINGS`; without it nothing is classified
      this way);
    * `crash` - an engine fell over or refused the file (Gacrux `### Error`
      pages, a timeout, a non-zero exit that is not "no pairing"); missing
      data, never a disagreement, and listed by site;
    * `unexplained_colour` / `unexplained_pairing` / `unexplained_split`
      - the same matches with a different first team, different matches,
      or one engine refusing a round the other pairs. Only these matter,
      and every round with one is dumped.

  The readings the 2026-09 probe of Gacrux found open (MarkDechamps/
  fide-swiss-pairing-engine, docs/research/gacrux-team-probe.md) and how
  this engine reads each - so a difference that one of them explains can
  be named, not guessed:

  | probe | question | Ainalrami | Gacrux 1.11.65 |
  |---|---|---|---|
  | G1 | 3.6.1 seats by TPN | TPN | TPN (fixed upstream; the probe's case 1 now pairs 1-3, 2-4) |
  | A6 | [C6] pass/fail or graded | graded | pass/fail -> `reading_c6_graded` |
  | - | [C6]'s "following scoregroup" when the next score level was emptied by upfloaters | the next non-empty level | the empty level, so no [C6] -> `reading_c6_following` (found here, seed 41 round 5 of the first smoke) |
  | - | a forfeited match makes a floater (1.5) | yes | no -> `reading_float_forfeit` (found here) |
  | A7 | "complies with" [C7] when 0 is unattainable | minimise | minimise |
  | A3 | a forfeited match is a meeting for [C1] | no | no |
  | A9 | a forfeit counts in 3.4.3's matches played | no | no |
  | A1 | Type B, last round, CD 0 after two same colours | strong (`Team.strong_preference/1` has no last-round guard) | strong |
  | A12 | 4.3.6 on squeezed histories | squeezed, from the end | squeezed, from the end |
  | A8 | floaters under acceleration | no team acceleration | - |

  So of the probe's readings only [C6] separates Ainalrami from Gacrux, and
  the probe's own reproducers (cases 1-6) were run against both before this
  harness existed: identical except case 2 ([C6], by design) and case 4b,
  whose file has no `320` record and so says nothing about the bye's match
  points - a file the generator never writes.

  ## Settings all three can be told

  Acceleration is not run: Ainalrami's team engine has none. Forbidden
  pairs (the "regional league" axis) are not run: Gacrux has no
  forbidden-pairs input (its `-u` is "unpaired teams", and no record is
  read as one). Colour type `:none` and "secondary score not used" are not
  drawn, and the PAB is always a drawn match - see
  `Ainalrami.Test.TeamThreeWay.options/1`.

  chesspairing is run with a local patch (`chesspairing-local.patch`, kept
  beside the binary on the VM) for six team-mode defects found here:

    * the repeat-pairing check compared teams against players' games;
    * a player's bye was credited to the team with the same number;
    * a `330` forfeited match hid every other match of its round (the
      round's recorded matches replaced, rather than joined, those read from
      the games);
    * a match read from the games took its first team from the lowest player
      number's game, not board 1's, so a `300` lineup out of roster order
      gave it the wrong colour history.
    * a `330` forfeited match (no boards) counted as played: colours and a
      meeting;
    * a team inherited its top-rated player's own PAB ineligibility (a
      board won by forfeit made the whole team ineligible).

  Unpatched, the first two alone make it refuse or mis-pair about a third
  of the rounds.

  ## Running it

      TEAM3_COUNT=200 TEAM3_SEED_FROM=1 \\
      GACRUX_DIR=... GACRUX_PYTHON=... CHESSPAIRING_EXE=... \\
      GACRUX_READINGS=/path/gacrux_readings.py \\
        mix test --only team_three_way test/ainalrami/team_three_way_test.exs

  Axis knobs are `TEAM3_*` (`Ainalrami.Test.TeamThreeWay.options/1`). The
  result is one `TEAM3SUM key=value ...` line for an aggregator, then the
  crash sites, then a readable table. Each axis needs its own `TMPDIR`:
  the adapters' scratch directories are unique within one VM, not across
  VMs sharing a directory, and a collision there once produced false
  agreement figures.
  """

  use ExUnit.Case

  alias Ainalrami.Test.{Chesspairing, Gacrux, TeamThreeWay}

  @moduletag :team_three_way
  @moduletag timeout: :infinity

  @pairs [ag: {:a, :g}, ac: {:a, :c}, gc: {:g, :c}]
  # Gacrux with one of its readings replaced by Ainalrami's: `{kind, [C6]
  # patches for the readings script, forfeit points in the player rows?}`.
  @readings [
    reading_c6_following: {"c6-next", false},
    reading_c6_graded: {"c6-graded", false},
    reading_c6_both: {"c6-graded,c6-next", false},
    reading_float_forfeit: {"flt-forfeit", false},
    reading_forfeit_gp: {nil, true},
    reading_combined: {"c6-next,flt-forfeit", true}
  ]
  @kinds ~w(identical reading_c6_following reading_c6_graded reading_c6_both reading_float_forfeit reading_forfeit_gp reading_combined crash unexplained_colour unexplained_pairing unexplained_split)a

  test "Ainalrami, Gacrux and chesspairing on identical team positions" do
    unless Gacrux.available?(), do: flunk("Gacrux not found at #{Gacrux.script_path()}")
    unless Chesspairing.available?(), do: flunk("chesspairing not found: #{Chesspairing.exe()}")

    count = env_int("TEAM3_COUNT", 10)
    seed_from = env_int("TEAM3_SEED_FROM", 1)
    concurrency = env_int("TEAM3_CONCURRENCY", System.schedulers_online())
    dump = System.get_env("TEAM3_DUMP")
    if dump, do: File.mkdir_p!(dump)

    rows =
      seed_from..(seed_from + count - 1)
      |> Task.async_stream(&run_event/1,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, rows} -> rows end)

    if dump, do: dump_rows(rows, dump, env_int("TEAM3_DUMP_LIMIT", 300))

    summary = summarise(rows, count, seed_from)
    IO.puts("\n" <> summary_line(summary))
    Enum.each(crash_lines(rows), &IO.puts/1)
    IO.puts(table(summary))

    self_fail = Enum.filter(rows, &(&1.self == :differs))
    a_err = Enum.filter(rows, &match?({:error, _}, &1.a))

    assert self_fail == [],
           "Ainalrami on the cut file differs from the generator's own pairing " <>
             "(a cut or reader defect, not a rules question): " <>
             inspect(Enum.map(self_fail, &{&1.seed, &1.round}))

    assert a_err == [],
           "Ainalrami errors: " <> inspect(Enum.map(a_err, &{&1.seed, &1.round, &1.a}))
  end

  # ---- one event -------------------------------------------------------------

  defp run_event(seed) do
    ev = TeamThreeWay.generate(seed)
    teams = Enum.to_list(1..ev.teams)

    for r <- 1..ev.rounds//1 do
      file = TeamThreeWay.file_for(ev.text, r, ev.boards)
      absent = TeamThreeWay.absent_teams(TeamThreeWay.cut(ev.text, r), r)

      a = TeamThreeWay.ainalrami(file)
      g = gacrux(file, r, [])
      c = chesspairing(file, teams)

      self =
        cond do
          absent != [] ->
            :skipped

          match?({:ok, _}, a) and same?(a, {:ok, Map.take(ev.pairings[r], [:matches, :bye])}) ->
            :same

          true ->
            :differs
        end

      # The counterfactual readings are run only when one can explain
      # something, and each at most once.
      {kind_ag, cache} = classify(cmp(a, g), a, {file, r}, %{})
      {kind_gc, cache} = classify(cmp(g, c), c, {file, r}, cache)
      # chesspairing has no counterfactual of its own; when it gives Gacrux's
      # answer, what separates Gacrux from Ainalrami separates it too.
      kind_ac =
        case {cmp(a, c), cmp(g, c)} do
          {:identical, _} ->
            :identical

          {kind, :identical} when kind != :crash ->
            if reading?(kind_ag), do: kind_ag, else: classify_plain(kind)

          {kind, _} ->
            classify_plain(kind)
        end

      kinds = %{ag: kind_ag, ac: kind_ac, gc: kind_gc}

      %{
        seed: seed,
        round: r,
        teams: ev.teams,
        boards: ev.boards,
        planned: ev.planned,
        file: file,
        absent: absent,
        a: a,
        g: g,
        c: c,
        gc: cache,
        self: self,
        kinds: kinds,
        matches: matches(a)
      }
    end
  end

  defp gacrux(file, r, opts) do
    case Gacrux.pair(file, r, [method: nil] ++ opts) do
      {:ok, pairs} -> TeamThreeWay.from_pairs(pairs)
      {:no_valid_pairing, _} -> :refused
      {:crashed, detail} -> {:crash, "510 " <> detail}
      {:error, {:timeout, _}} -> {:crash, "timeout"}
      {:error, {code, out}} -> {:crash, "#{code} #{first_line(out)}"}
    end
  end

  defp chesspairing(file, teams) do
    case Chesspairing.pair(file, teams) do
      {:ok, pairs} -> TeamThreeWay.from_pairs(pairs)
      :refused -> :refused
      {:error, {:timeout, _}} -> {:crash, "timeout"}
      {:error, {code, out}} -> {:crash, "#{inspect(code)} #{first_line(out)}"}
      {:error, {:teams_missing, missing, _}} -> {:crash, "teams missing #{inspect(missing)}"}
    end
  end

  defp readings_script, do: System.get_env("GACRUX_READINGS")

  defp first_line(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, 160)
  end

  defp first_line(other), do: inspect(other)

  defp ok_or_refused?({:ok, _}), do: true
  defp ok_or_refused?(:refused), do: true
  defp ok_or_refused?(_), do: false

  defp matches({:ok, %{matches: m}}), do: length(m)
  defp matches(_), do: 0

  # ---- comparing -------------------------------------------------------------

  defp same?({:ok, x}, {:ok, y}), do: TeamThreeWay.oriented(x) == TeamThreeWay.oriented(y)
  defp same?(:refused, :refused), do: true
  defp same?(_, _), do: false

  defp cmp({:ok, x}, {:ok, y}) do
    cond do
      TeamThreeWay.oriented(x) == TeamThreeWay.oriented(y) -> :identical
      TeamThreeWay.composition(x) == TeamThreeWay.composition(y) -> :colour
      true -> :pairing
    end
  end

  defp cmp(:refused, :refused), do: :identical
  defp cmp(:refused, {:ok, _}), do: :split
  defp cmp({:ok, _}, :refused), do: :split
  defp cmp(_, _), do: :crash

  # The other engine's answer, `other`, against Gacrux run with one reading
  # after another replaced (`@readings`): the first that gives it names the
  # difference. A reading that cannot apply (no script, no `330`) is skipped.
  defp classify(kind, _other, _at, cache) when kind in [:identical, :crash],
    do: {kind, cache}

  defp classify(kind, other, {file, r}, cache) do
    readings = Enum.filter(@readings, fn {_, reading} -> applies?(reading, file) end)

    if ok_or_refused?(other) do
      Enum.reduce_while(readings, {classify_plain(kind), cache}, fn {name, reading}, {k, cache} ->
        {g, cache} =
          case cache do
            %{^reading => g} -> {g, cache}
            _ -> gacrux_reading(file, r, reading) |> then(&{&1, Map.put(cache, reading, &1)})
          end

        if cmp(other, g) == :identical, do: {:halt, {name, cache}}, else: {:cont, {k, cache}}
      end)
    else
      {classify_plain(kind), cache}
    end
  end

  defp applies?({patches, rows?}, file),
    do: (patches == nil or readings_script() != nil) and (not rows? or file =~ "\n330 ")

  defp gacrux_reading(file, r, {patches, rows?}) do
    file = if rows?, do: TeamThreeWay.forfeit_points_in_rows(file), else: file
    opts = if patches, do: [script: [readings_script(), patches]], else: []
    gacrux(file, r, opts)
  end

  defp reading?(kind), do: kind |> to_string() |> String.starts_with?("reading_")

  defp classify_plain(:crash), do: :crash
  defp classify_plain(:colour), do: :unexplained_colour
  defp classify_plain(:pairing), do: :unexplained_pairing
  defp classify_plain(:split), do: :unexplained_split

  defp unexplained?(row),
    do:
      Enum.any?(
        Map.values(row.kinds),
        &(&1 in ~w(unexplained_colour unexplained_pairing unexplained_split)a)
      )

  # ---- reporting ---------------------------------------------------------------

  defp summarise(rows, count, seed_from) do
    pair_counts =
      for {name, _} <- @pairs, kind <- @kinds, into: %{} do
        {"#{name}_#{kind}", Enum.count(rows, &(&1.kinds[name] == kind))}
      end

    three =
      rows
      |> Enum.filter(fn r -> Enum.all?([r.a, r.g, r.c], &ok_or_refused?/1) end)
      |> Enum.map(fn r ->
        case {same?(r.a, r.g), same?(r.a, r.c), same?(r.g, r.c)} do
          {true, true, true} -> "three_all_agree"
          {false, false, true} -> "three_a_odd"
          {false, true, false} -> "three_g_odd"
          {true, false, false} -> "three_c_odd"
          _ -> "three_all_differ"
        end
      end)
      |> Enum.frequencies()

    Map.merge(pair_counts, %{
      "seed_from" => seed_from,
      "tournaments" => count,
      "rounds" => length(rows),
      "matches" => Enum.sum(Enum.map(rows, & &1.matches)),
      "boards" => Enum.sum(Enum.map(rows, &(&1.matches * &1.boards))),
      "rounds_three" => three |> Map.values() |> Enum.sum(),
      "self_same" => Enum.count(rows, &(&1.self == :same)),
      "self_differs" => Enum.count(rows, &(&1.self == :differs)),
      "a_refused" => Enum.count(rows, &(&1.a == :refused)),
      "gc_run" => Enum.count(rows, &(&1.gc != %{})),
      "unexplained_rounds" => Enum.count(rows, &unexplained?/1)
    })
    |> Map.merge(
      Map.new(
        ~w(three_all_agree three_a_odd three_g_odd three_c_odd three_all_differ),
        &{&1, Map.get(three, &1, 0)}
      )
    )
  end

  defp summary_line(summary) do
    "TEAM3SUM " <>
      (summary |> Enum.sort() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end))
  end

  defp crash_lines(rows) do
    for row <- rows,
        {engine, answer} <-
          [ainalrami: row.a, gacrux: row.g, chesspairing: row.c] ++
            Enum.map(row.gc, fn {reading, g} -> {"gacrux #{label(reading)}", g} end),
        {:crash, detail} <- [answer] do
      {engine, site(detail), {row.seed, row.round}}
    end
    |> Enum.group_by(fn {e, s, _} -> {e, s} end, fn {_, _, at} -> at end)
    |> Enum.sort()
    |> Enum.map(fn {{engine, site}, at} ->
      "TEAM3CRASH engine=#{engine} count=#{length(at)} first=#{inspect(hd(at))} site=#{site}"
    end)
  end

  # A crash's site without the numbers that differ between instances.
  defp site(detail), do: detail |> String.replace(~r/\d+/, "N") |> String.slice(0, 140)

  defp table(s) do
    pct = fn n ->
      if s["rounds"] == 0,
        do: "-",
        else: :erlang.float_to_binary(100 * n / s["rounds"], decimals: 4)
    end

    rows =
      for {name, _} <- @pairs do
        cells = Enum.map(@kinds, &s["#{name}_#{&1}"])

        "  #{name}  " <>
          Enum.map_join(cells, "  ", &String.pad_leading(to_string(&1), 9)) <>
          "   identical #{pct.(s["#{name}_identical"])}%"
      end

    """

    Team three-way, seeds #{s["seed_from"]}..#{s["seed_from"] + s["tournaments"] - 1}: #{s["rounds"]} rounds, #{s["matches"]} matches, #{s["boards"]} boards
          #{Enum.map_join(@kinds, "  ", &String.pad_leading(header(&1), 9))}
    #{Enum.join(rows, "\n")}
      three-way (no crash): #{s["rounds_three"]} rounds - all agree #{s["three_all_agree"]}, Ainalrami odd #{s["three_a_odd"]}, Gacrux odd #{s["three_g_odd"]}, chesspairing odd #{s["three_c_odd"]}, all differ #{s["three_all_differ"]}
      self-check against the generator: #{s["self_same"]} same, #{s["self_differs"]} differ
      UNEXPLAINED rounds: #{s["unexplained_rounds"]}
    """
  end

  defp label({patches, rows?}),
    do: Enum.join(Enum.reject([patches, rows? && "forfeit-rows"], &(&1 in [nil, false])), "+")

  defp header(kind) do
    case to_string(kind) do
      "reading_c6_" <> r -> "c6 " <> r
      "reading_forfeit_gp" -> "ff gp"
      "reading_float_forfeit" -> "ff float"
      "reading_combined" -> "combined"
      "unexplained_" <> r -> "UNEX " <> r
      k -> k
    end
    |> String.slice(0, 9)
  end

  defp dump_rows(rows, dir, limit) do
    rows
    |> Enum.filter(&(unexplained?(&1) or &1.self == :differs))
    |> Enum.sort_by(&{&1.seed, &1.round})
    |> Enum.take(limit)
    |> Enum.each(fn row ->
      base = Path.join(dir, "seed#{row.seed}_r#{row.round}")
      File.write!(base <> ".trf", row.file)

      File.write!(
        base <> ".txt",
        """
        seed #{row.seed} round #{row.round} (#{row.teams} teams, #{row.boards} boards, #{row.planned} rounds planned)
        options: #{inspect(TeamThreeWay.options(row.seed))}
        kinds: #{inspect(row.kinds)}
        announced absent in the generator (not in the file): #{inspect(row.absent)}
        self-check: #{row.self}
        ainalrami:       #{show(row.a)}
        gacrux:          #{show(row.g)}
        chesspairing:    #{show(row.c)}
        """ <> Enum.map_join(row.gc, fn {p, g} -> "gacrux #{label(p)}: #{show(g)}\n" end)
      )
    end)
  end

  defp show({:ok, %{matches: m, bye: b}}),
    do: Enum.map_join(Enum.sort(m), " ", fn {w, b} -> "#{w}-#{b}" end) <> "  bye #{inspect(b)}"

  defp show(other), do: inspect(other)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end
end
