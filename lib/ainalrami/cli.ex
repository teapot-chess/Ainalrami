defmodule Ainalrami.CLI do
  @moduledoc """
  Command-line entry point. Deliberately mirrors JaVaFo's own invocation
  shape - `java -jar javafo.jar input.trf -p output.txt` (confirmed against
  the sibling project's real `System.cmd` call, not guessed) - as
  `ainalrami input.trf -p output.trf`, so a caller that already knows how to
  drive JaVaFo only has to swap the executable name, not rewrite its
  argument-building code. The same applies to JaVaFo's other two modes:
  `-c` (Pairings Checker, FPC) is implemented - it replays a completed
  tournament and diffs each round against what this engine would have
  paired, exiting nonzero if any round differs; a team Swiss is replayed
  team against team with the C.04.6 engine (`Ainalrami.TeamReplay`), a
  team round robin against the Berger tables, and a file whose system it
  cannot replay (an individual round robin, Scheveningen, Schiller,
  knockout, Dubov, Burstein, custom system ...) exits 2 with a message
  saying so. `-g` (Random Tournament Generator) is implemented too - it
  takes no input file, since it creates a tournament rather than reading
  one; `-g --team=swiss|roundrobin` generates a team event
  (`Ainalrami.TeamGenerator`).

  `-p` and `-x` on a team file pair the next round team against team
  (`Ainalrami.TeamCLI`, whose moduledoc defines the output format).

  `-s` prints the standings by the file's tie-break list, which is what
  `-c` checks the file's own ranks against.

  Every pairing option the library takes has a flag, a record in the file
  (`Ainalrami.Trf`, "The organiser's records"), or both; the flags are laid
  over the parsed file in `with_input_flags/2`, so each mode reads one
  place. docs/cli-parity.md is the table.

  Verbose trace is the default (see `Ainalrami.Log`); pass `-q`/`--quiet` to
  suppress it.

  `run/1` does the real work and returns a plain exit code, deliberately
  never calling `System.halt/1` itself - that would kill the test VM if
  called from ExUnit. `main/1` (the actual escript entry point) is the only
  place that halts.
  """

  alias Ainalrami.{
    Acceleration,
    ByePreference,
    Dubov,
    DubovCLI,
    EventFormat,
    Generator,
    Log,
    Pairing,
    PairingInput,
    RoundRobin,
    RoundRobinGenerator,
    TeamCLI,
    TeamGenerator,
    TeamReplay,
    Trf,
    TypeCode
  }

  @doc false
  def main(argv), do: argv |> run() |> System.halt()

  # Wraps `run/1`'s body so a value-level complaint thrown from option parsing
  # comes back as an ordinary usage error. A throw rather than a return value
  # because those parsers are called for their VALUE - `option/2` hands back an
  # integer, and there is nowhere in `seed: option(flags, "seed")` for an error
  # tuple to go that is not just as silent as the bug this fixes.

  @doc "Runs the CLI and returns an exit code, without halting the VM - see moduledoc."
  def run(argv) do
    {flags, positional} = split_flags(argv)

    Log.set_level(
      cond do
        "-q" in flags or "--quiet" in flags -> :quiet
        "-d" in flags or "--debug" in flags -> :debug
        true -> :normal
      end
    )

    try do
      cond do
        # Before --help and --version, so a mistyped option is reported rather
        # than swallowed by a run that was going to print help anyway.
        complaint = bad_flag(flags) -> usage_error(complaint)
        "-h" in flags or "--help" in flags -> print_help_and_ok()
        "--version" in flags -> print_version_and_ok()
        true -> dispatch(positional, flags)
      end
    rescue
      # The backstop. Everything below here that CAN be predicted is already
      # reported as a message and an exit code - an unreadable file, an
      # invalid TRF, an option this program does not have. What was left was
      # everything else: a `260` line in the trace (sweep H2) reached the
      # user as `** (Protocol.UndefinedError) protocol Enumerable not
      # implemented for Tuple`, an escript stack trace with no indication of
      # which file or which line, and - because `main/1` halts on `run/1`'s
      # return value and an uncaught raise never returns one - an exit status
      # that depended on the VM rather than on this program.
      #
      # So an unexpected exception becomes the same contract as every
      # expected one: a message on stderr, exit 1. Without the help text,
      # which is for a caller who typed something wrong, not for this.
      e ->
        Log.error("unexpected error: #{Exception.message(e)}")
        1
    catch
      {:usage, message} -> usage_error(message)
    end
  end

  # Every flag this CLI accepts. Both lists are checked rather than pattern
  # matched, because the failure they prevent is silence.
  #
  # `--player=30` (singular) used to run with a RANDOM roster size.
  # `--initial-colour=x` used to quietly pick White. And
  # `ainalrami -g out.trf --seed 42` - a space instead of an equals sign -
  # used to write the file and ignore the seed, which makes the run
  # unreproducible, which is the whole argument for the generator existing.
  #
  # Each of those is a command that appears to work. The seed one is the worst
  # kind: it produces a real tournament that can never be produced again, and
  # nothing says so.
  @bare_flags ~w(-p -g -c -x --explain -q --quiet -d --debug -h --help --version --lineups
                 --roundrobin --match-format -s --standings --cascade-order
                 --bye-alternatives --float-alternatives --alternative-pairs)
  @valued_flags ~w(seed players rounds forfeit-pct bye-pct forbidden-pct
                   acceleration initial-colour initial-color force absent
                   ratings rating-range rating-top rating-step rating-sigma
                   results draw-rate full-bye-pct half-bye-pct zero-bye-pct
                   forfeit-win-pct double-forfeit-pct odd-results-pct tie-breaks
                   unset unset-chance bye-want bye-want-soft bye-avoid bye-avoid-soft
                   team teams boards reserves cycles team-type score secondary
                   match-points pab forfeit-match-points match-forfeit-pct
                   absent-team-pct absent-player-pct out-of-order-pct
                   groups soft-pairs soft-position team-forbidden team-soft-pairs
                   forbidden bye-exclude virtual-points baku-group-a half-bye zero-bye
                   full-bye absent-teams judge points max-upfloater-sets explain-limit
                   cap-rounds max-candidates dialect proof system provisional-rating)

  # `-g` options that only an individual tournament has, and the ones only
  # a team event has (`--team=...`); each refused for the other.
  @individual_generator_flags ~w(players bye-pct forbidden-pct acceleration ratings
                                 rating-range rating-top rating-step rating-sigma results
                                 full-bye-pct half-bye-pct zero-bye-pct forfeit-win-pct
                                 double-forfeit-pct odd-results-pct unset unset-chance groups system)
  @team_generator_flags ~w(teams boards reserves cycles team-type score secondary
                           match-points pab forfeit-match-points match-forfeit-pct
                           absent-team-pct absent-player-pct out-of-order-pct)

  # `-c`'s (and a team file's `-p`/`-x`) exit code when the rounds could not be replayed at all because
  # the file's pairing system is not one this checker replays - distinct
  # from 1, which says something was compared and differed. A standings
  # difference still exits 1: that WAS compared.
  @not_replayed 2

  defp split_flags(argv), do: Enum.split_with(argv, &String.starts_with?(&1, "-"))

  # The first flag this program does not accept, described, or nil.
  defp bad_flag(flags), do: Enum.find_value(flags, &flag_complaint/1)

  defp flag_complaint(flag) do
    cond do
      flag in @bare_flags ->
        nil

      String.contains?(flag, "=") and name_of(flag) in @valued_flags ->
        nil

      # Written correctly but not a flag this program has. Named back, because
      # the mistake is almost always a plural or a spelling.
      String.contains?(flag, "=") ->
        "unknown option --#{name_of(flag)}"

      # A valued flag with a space instead of an equals sign. Worth its own
      # message: the shell has already split it, so the value is sitting in
      # the positional arguments looking like a file name, and the run happens
      # without the option.
      String.trim_leading(flag, "-") in @valued_flags ->
        "#{flag} takes its value with an equals sign, as #{flag}=VALUE - " <>
          "written with a space the value is read as a file name and the option is lost"

      true ->
        "unknown option #{flag}"
    end
  end

  defp name_of(flag) do
    flag |> String.trim_leading("-") |> String.split("=") |> hd()
  end

  # The one `-g` option whose value is a word rather than an integer.
  #
  # An unknown value is refused rather than treated as absent. The name being
  # known is not enough - `--acceleration=bakku` is a request for something
  # this program does not do, and running without acceleration is not that.
  defp acceleration_option(flags) do
    Enum.find_value(flags, fn
      "--acceleration=baku" -> :baku
      "--acceleration=random" -> :random
      "--acceleration=" <> other -> refuse("unknown acceleration \"#{other}\" - baku or random")
      _ -> nil
    end)
  end

  # Article 5.1's drawing of lots, for `-g`. Accepts either spelling of
  # each colour and defaults to White, which is what the generator always
  # used implicitly before the option existed.
  defp initial_colour_option(flags) do
    Enum.find_value(flags, "w", fn
      "--initial-colour=" <> value -> normalise_colour(value) || bad_colour(value)
      "--initial-color=" <> value -> normalise_colour(value) || bad_colour(value)
      _ -> nil
    end)
  end

  # Refused rather than silently defaulted. Somebody who typed a colour has an
  # answer in mind, and quietly running the opposite one is worse than
  # stopping.
  defp bad_colour(value) do
    refuse("unknown initial colour \"#{value}\" - white/w or black/b")
  end

  defp bounded(nil, _key, _minimum), do: nil
  defp bounded(value, _key, minimum) when value >= minimum, do: value

  defp bounded(value, key, minimum) do
    refuse("--#{key} must be at least #{minimum}, not #{value}")
  end

  # A complaint from deep inside option parsing, where returning an exit code
  # would just be ignored by the caller expecting a value. Caught in `run/1`.
  defp refuse(message), do: throw({:usage, message})

  defp normalise_colour(value) do
    case String.downcase(value) do
      v when v in ["w", "white"] -> "w"
      v when v in ["b", "black"] -> "b"
      _ -> nil
    end
  end

  # `--key=value` options, used only by `-g`. Anything unrecognised is left
  # for the mode to reject rather than silently ignored.
  # An unparsable value is refused, not treated as absent. `--seed=fourty2`
  # producing a random seed is the same unreproducible run as `--seed 42` did.
  defp option(flags, key) do
    prefix = "--#{key}="

    case Enum.find(flags, &String.starts_with?(&1, prefix)) do
      nil ->
        nil

      flag ->
        value = String.trim_leading(flag, prefix)

        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> refuse("--#{key} takes a whole number, not \"#{value}\"")
        end
    end
  end

  # The value of `--key=...` as text, or nil.
  defp text_option(flags, key) do
    prefix = "--#{key}="

    Enum.find_value(flags, fn flag ->
      if String.starts_with?(flag, prefix), do: String.trim_leading(flag, prefix)
    end)
  end

  # `--ratings=2400,2350,...` (Q27), `--rating-range=1400-2700` (Q28), or
  # `--rating-top=2600 --rating-step=20 [--rating-sigma=50]` (Q28). At most
  # one of the three shapes.
  defp ratings_option(flags) do
    list = text_option(flags, "ratings")
    range = text_option(flags, "rating-range")
    top = option(flags, "rating-top")
    step = option(flags, "rating-step")
    sigma = option(flags, "rating-sigma")

    given = Enum.count([list, range, top], &(not is_nil(&1)))

    cond do
      given > 1 ->
        refuse("--ratings, --rating-range and --rating-top are alternatives - give one")

      list ->
        list
        |> String.split(",", trim: true)
        |> Enum.map(fn r ->
          case Integer.parse(String.trim(r)) do
            {rating, ""} when rating >= 0 -> rating
            _ -> refuse("--ratings takes whole numbers separated by commas, not \"#{r}\"")
          end
        end)

      range ->
        case String.split(range, "-") do
          [low, high] ->
            with {low, ""} <- Integer.parse(low),
                 {high, ""} <- Integer.parse(high),
                 true <- low <= high do
              {:range, low, high}
            else
              _ -> refuse("--rating-range takes LOW-HIGH, not \"#{range}\"")
            end

          _ ->
            refuse("--rating-range takes LOW-HIGH, not \"#{range}\"")
        end

      top ->
        step = step || refuse("--rating-top needs --rating-step")
        if sigma, do: {:step, top, step, sigma}, else: {:step, top, step}

      step || sigma ->
        refuse("--rating-step and --rating-sigma need --rating-top")

      true ->
        nil
    end
  end

  defp unset_option(flags) do
    case text_option(flags, "unset") do
      nil -> :random
      "random" -> :random
      "fixed" -> :fixed
      other -> refuse("unknown --unset \"#{other}\" - random or fixed")
    end
  end

  defp bounded_pct(nil, _name), do: nil
  defp bounded_pct(value, _name) when value in 0..100, do: value
  defp bounded_pct(value, name), do: refuse("--#{name} takes 0 to 100, not #{value}")

  defp results_option(flags) do
    case text_option(flags, "results") do
      nil -> nil
      "fide" -> :fide
      "uniform" -> :uniform
      other -> refuse("unknown --results \"#{other}\" - fide or uniform")
    end
  end

  defp fraction_option(flags, key) do
    case text_option(flags, key) do
      nil ->
        nil

      text ->
        case Float.parse(text) do
          {value, ""} when value >= 0 and value <= 1 -> value
          _ -> refuse("--#{key} takes a number from 0 to 1, not \"#{text}\"")
        end
    end
  end

  # `--tie-breaks=BH/C1,BH,SB` (Q31): checked here, so a misspelt code is a
  # usage error rather than a generated file with a list nobody can apply.
  defp tie_breaks_option(flags) do
    case text_option(flags, "tie-breaks") do
      nil ->
        nil

      text ->
        case Ainalrami.Tiebreaks.Code.parse_list(text) do
          {:ok, codes} -> Enum.map(codes, &Ainalrami.Tiebreaks.Code.format/1)
          {:error, reason} -> refuse("--tie-breaks: #{reason}")
        end
    end
  end

  # `input.trf -p [output.trf]` - input file is always the first positional
  # argument, exactly like JaVaFo; the mode flag then decides what happens
  # to the rest.
  # `-g` is the one mode that takes no input file - it creates a
  # tournament rather than reading one - so it's dispatched before the
  # missing-input check.
  defp dispatch(positional, flags) do
    prefs = bye_preferences_option(flags)

    cond do
      prefs != [] and ("-g" in flags or "-c" in flags) ->
        usage_error(
          "the bye preferences (--bye-want, --bye-want-soft, --bye-avoid, " <>
            "--bye-avoid-soft) apply to -p and -x only - -g and -c pair by the FIDE rules alone"
        )

      (flag = given(flags, ~w(soft-pairs soft-position))) && ("-g" in flags or "-c" in flags) ->
        usage_error(
          "--#{flag} applies to -p and -x only - soft pairs are an organiser's wish, and " <>
            "-g and -c pair by the FIDE rules alone"
        )

      complaint = misplaced_flag(flags, mode(flags)) ->
        usage_error(complaint)

      text_option(flags, "max-candidates") &&
          is_nil(given(flags, ~w(bye-alternatives float-alternatives))) ->
        usage_error("--max-candidates caps --bye-alternatives or --float-alternatives; give one")

      "-g" in flags and text_option(flags, "team") != nil ->
        generate_team(positional, flags)

      "-g" in flags and "--roundrobin" in flags ->
        generate_round_robin(positional, flags)

      "-g" in flags ->
        case given(flags, @team_generator_flags) do
          nil -> generate(positional, flags)
          flag -> usage_error("--#{flag} is a team event's option - add --team=swiss|roundrobin")
        end

      positional == [] ->
        usage_error("missing input TRF file")

      "-p" in flags ->
        pair_checked(hd(positional), tl(positional), prefs, flags)

      "-c" in flags ->
        check(hd(positional), flags)

      "-x" in flags or "--explain" in flags ->
        explain(hd(positional), flags, prefs)

      "-s" in flags or "--standings" in flags ->
        standings(hd(positional), tl(positional), flags)

      true ->
        usage_error("missing mode flag: one of -p, -g, -c, -x, -s")
    end
  end

  # `--bye-want=5,12@3-4+7` and its three siblings: the organiser's bye
  # preferences (`Ainalrami.ByePreference`, not a FIDE rule). Each flag
  # takes starting ranks separated by commas, each optionally followed by
  # `@` and the rounds it applies to - single rounds and ranges joined by
  # `+` - and may be given more than once. Refused rather than skipped when
  # malformed: a preference silently dropped pairs the round by other rules
  # than the ones asked for.
  @bye_preference_flags [
    {"bye-want", :want_hard},
    {"bye-want-soft", :want_soft},
    {"bye-avoid", :avoid_hard},
    {"bye-avoid-soft", :avoid_soft}
  ]

  defp bye_preferences_option(flags) do
    for flag <- flags,
        {name, pref} <- @bye_preference_flags,
        String.starts_with?(flag, "--#{name}="),
        item <- flag |> String.trim_leading("--#{name}=") |> String.split(",", trim: true) do
      bye_preference_item(String.trim(item), name, pref)
    end
  end

  defp bye_preference_item(item, name, pref) do
    bad = fn ->
      refuse(
        "--#{name} takes starting ranks separated by commas, each optionally with " <>
          "@ROUNDS (e.g. 5,12@3-4+7), not \"#{item}\""
      )
    end

    case String.split(item, "@") do
      [rank] ->
        {positive_int(rank) || bad.(), pref}

      [rank, rounds] ->
        rounds = rounds |> String.split("+", trim: true) |> Enum.flat_map(&round_span(&1, bad))
        if rounds == [], do: bad.(), else: {positive_int(rank) || bad.(), pref, rounds}

      _ ->
        bad.()
    end
  end

  defp round_span(part, bad) do
    case String.split(part, "-") do
      [n] ->
        [positive_int(n) || bad.()]

      [a, b] ->
        with a when is_integer(a) <- positive_int(a),
             b when is_integer(b) and b >= a <- positive_int(b) do
          Enum.to_list(a..b)
        else
          _ -> bad.()
        end

      _ ->
        bad.()
    end
  end

  # `--groups=1-8/9-12,15`: pairing groups, `/` between groups, `,` between
  # ranks and `a-b` for a run of them - what the file's `XXG` lines say,
  # given on the command line (and taking their place). A file OpenPairings
  # writes does not carry its categories, so this is how a tournament it
  # pairs by category is paired here.
  defp groups_option(flags) do
    case text_option(flags, "groups") do
      nil ->
        nil

      text ->
        bad = fn ->
          refuse(
            "--groups takes groups of starting ranks separated by /, the ranks by commas " <>
              "or as a-b (e.g. 1-8/9-12,15), not \"#{text}\""
          )
        end

        groups =
          text
          |> String.split("/")
          |> Enum.map(fn group ->
            group
            |> String.split(",", trim: true)
            |> Enum.flat_map(&round_span(String.trim(&1), bad))
            |> case do
              [] -> bad.()
              ranks -> ranks
            end
          end)

        all = List.flatten(groups)

        case all -- Enum.uniq(all) do
          [] -> groups
          [rank | _] -> refuse("--groups puts #{rank} in two groups")
        end
    end
  end

  # `--soft-pairs=1,4/2,9,12@3-5` and `--soft-position=strong|weak`: pairs to
  # keep apart where the criteria allow it (`Ainalrami.Pairing`'s
  # `:soft_pairs`, OpenPairings' soft forbidden pairings and club
  # protection), a group optionally for a range of rounds - an organiser's
  # wish, not a FIDE rule, so `-p` and `-x` only, as the bye preferences
  # are. `{pairs, position}`, either nil when not given;
  # `organiser_options/3` adds them to the file's `XXO` records.
  defp soft_flags(flags) do
    pairs =
      case groups_of(flags, "soft-pairs") do
        [] -> nil
        groups -> groups
      end

    position =
      case text_option(flags, "soft-position") do
        nil -> nil
        "strong" -> :strong
        "weak" -> :weak
        other -> refuse("unknown --soft-position \"#{other}\" - strong or weak")
      end

    {pairs, position}
  end

  # The command line's `--match-format` and `--groups=` laid over what the
  # file says (`XXM`, `XXG`), so every mode reads one place. A rank the file
  # does not have is refused, as the parser refuses one in an `XXG` line.
  defp with_format_flags(parsed, flags) do
    tournament =
      if "--match-format" in flags,
        do: Map.put(parsed.tournament, :match_format, true),
        else: parsed.tournament

    tournament =
      case groups_option(flags) do
        nil ->
          tournament

        groups ->
          ranks = MapSet.new(parsed.players, & &1.rank)

          case Enum.find(List.flatten(groups), &(not MapSet.member?(ranks, &1))) do
            nil -> Map.put(tournament, :pairing_groups, groups)
            rank -> refuse("--groups names #{rank}, which is not a starting rank in this file")
          end
      end

    %{parsed | tournament: tournament}
  end

  defp positive_int(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 -> n
      _ -> nil
    end
  end

  # ---- the rest of the library's options, on the command line ---------------
  #
  # Everything below lays a flag over what the file says, so that `-p`, `-x`,
  # `-c` and `-s` read one place - `parsed` - whichever way the option
  # arrived. docs/cli-parity.md has the whole table: library option, flag,
  # record.

  # Which mode a run is in, for the flags that only some modes have.
  defp mode(flags) do
    cond do
      "-g" in flags -> :generate
      "-p" in flags -> :pair
      "-c" in flags -> :check
      "-x" in flags or "--explain" in flags -> :explain
      "-s" in flags or "--standings" in flags -> :standings
      true -> nil
    end
  end

  @mode_flags %{pair: "-p", explain: "-x", check: "-c", standings: "-s", generate: "-g"}

  # The flags that mean something in some modes and nothing in the others.
  # Refused in the others, not ignored: a run that drops an option without a
  # word is the failure this file's first comment is about.
  @flag_modes %{
    "forbidden" => [:pair, :explain, :check],
    "virtual-points" => [:pair, :explain, :check],
    "baku-group-a" => [:pair, :explain, :check],
    "points" => [:pair, :explain, :check, :standings],
    "max-upfloater-sets" => [:pair, :explain, :check],
    "bye-exclude" => [:pair, :explain],
    "bye-want" => [:pair, :explain],
    "bye-want-soft" => [:pair, :explain],
    "bye-avoid" => [:pair, :explain],
    "bye-avoid-soft" => [:pair, :explain],
    "soft-pairs" => [:pair, :explain],
    "soft-position" => [:pair, :explain],
    "team-forbidden" => [:pair, :explain, :check],
    "team-soft-pairs" => [:pair, :explain],
    "half-bye" => [:pair, :explain],
    "zero-bye" => [:pair, :explain],
    "full-bye" => [:pair, :explain],
    "absent-teams" => [:pair, :explain],
    "cascade-order" => [:pair],
    "proof" => [:pair],
    "judge" => [:explain],
    "bye-alternatives" => [:explain],
    "float-alternatives" => [:explain],
    "alternative-pairs" => [:explain],
    "max-candidates" => [:explain],
    "explain-limit" => [:explain],
    "force" => [:explain],
    "absent" => [:explain],
    "cap-rounds" => [:check, :standings],
    "dialect" => [:generate],
    "system" => [:pair, :explain, :check, :generate],
    "provisional-rating" => [:pair, :check]
  }

  defp misplaced_flag(_flags, nil), do: nil

  defp misplaced_flag(flags, mode) do
    Enum.find_value(flags, fn flag ->
      name = name_of(flag)

      case Map.get(@flag_modes, name) do
        nil ->
          nil

        modes ->
          if mode in modes do
            nil
          else
            "--#{name} is for #{Enum.map_join(modes, ", ", &@mode_flags[&1])}, " <>
              "not #{@mode_flags[mode]}"
          end
      end
    end)
  end

  # Flags a file of the wrong kind cannot use.
  @individual_only ~w(forbidden bye-exclude virtual-points baku-group-a acceleration judge
                      bye-alternatives float-alternatives alternative-pairs max-candidates
                      cascade-order proof)
  @team_swiss_only ~w(team-type score secondary max-upfloater-sets explain-limit
                      team-forbidden team-soft-pairs)
  @bye_flags ~w(half-bye zero-bye full-bye absent-teams)

  defp with_input_flags(parsed, flags) do
    parsed
    |> with_format_flags(flags)
    |> with_rounds_flag(flags)
    |> with_colour_flag(flags)
    |> with_points_flag(flags)
    |> with_forbidden_flag(flags)
    |> with_team_apart_flags(flags)
    |> with_acceleration_flags(flags)
    |> with_tie_break_flag(flags)
    |> with_bye_flags(flags)
  end

  # `--rounds=N` on `-p`, `-x` and `-c`: the tournament's round count, in
  # place of the file's `142`/`XXR` - `:expected_rounds`, which the last
  # round's colour rules key off.
  defp with_rounds_flag(parsed, flags) do
    case bounded(option(flags, "rounds"), "rounds", 1) do
      nil -> parsed
      rounds -> put_in(parsed.tournament[:number_of_rounds], rounds)
    end
  end

  # `--initial-colour=white|black`: Article 5.1's drawing of lots, in place
  # of the file's `152`/`XXC`.
  defp with_colour_flag(parsed, flags) do
    if text_option(flags, "initial-colour") || text_option(flags, "initial-color"),
      do: put_in(parsed.tournament[:initial_colour], initial_colour_option(flags)),
      else: parsed
  end

  @point_words %{
    "win" => :win,
    "draw" => :draw,
    "loss" => :loss,
    "bye" => :pairing_allocated_bye,
    "pab" => :pairing_allocated_bye,
    "forfeit-loss" => :forfeit_loss,
    "zero-bye" => :zero_point_bye,
    "half-bye" => :half_point_bye,
    "full-bye" => :full_point_bye,
    "forfeit-win" => :forfeit_win,
    # TRF26's `?`, a result not on record: `162`'s `X`. Without it a `?`
    # is worth a draw, the format's own default (`Trf.points_for/2`).
    "unknown" => :unknown
  }

  # `--points=3,1,0` (win, draw, loss) or `--points=win:3,draw:1,bye:1`: the
  # point system (`:point_system`), over the file's `BB*`/`162` or the
  # standard one. As `BBW` does, a win's value moves the pairing-allocated
  # bye with it unless `bye:` says otherwise. The players' totals are moved
  # to the new system (`PairingInput.rescore/3`): the file's were added up
  # under the old one.
  defp with_points_flag(parsed, flags) do
    case text_option(flags, "points") do
      nil ->
        parsed

      text ->
        bad = fn ->
          refuse(
            "--points takes WIN,DRAW,LOSS (e.g. 3,1,0) or NAME:VALUE pairs separated by " <>
              "commas (#{@point_words |> Map.keys() |> Enum.sort() |> Enum.join(", ")}), " <>
              "not \"#{text}\""
          )
        end

        number = fn value ->
          case Float.parse(String.trim(value)) do
            {n, ""} when n >= 0 -> n
            _ -> bad.()
          end
        end

        parts = String.split(text, ",", trim: true)

        given =
          cond do
            parts == [] ->
              bad.()

            Enum.all?(parts, &String.contains?(&1, ":")) ->
              Enum.map(parts, fn part ->
                [name, value] = String.split(part, ":", parts: 2)
                {Map.get(@point_words, String.trim(name)) || bad.(), number.(value)}
              end)

            length(parts) == 3 and not Enum.any?(parts, &String.contains?(&1, ":")) ->
              Enum.zip([:win, :draw, :loss], Enum.map(parts, number))

            true ->
              bad.()
          end

        old = parsed.tournament[:point_system] || Trf.default_point_system()
        new = Map.merge(old, Map.new(given))

        # A `?` the file left unvalued is counted at the flag's value on both
        # sides of the rescore - the flag is the `X` the file did not write -
        # so the total stays what the file says, exactly
        # as it would had the file carried `162 X` itself.
        old =
          if Map.has_key?(new, :unknown),
            do: Map.put_new(old, :unknown, new.unknown),
            else: old

        new =
          if Keyword.has_key?(given, :win) and not Keyword.has_key?(given, :pairing_allocated_bye),
            do: Map.put(new, :pairing_allocated_bye, new.win),
            else: new

        %{
          parsed
          | tournament: Map.put(parsed.tournament, :point_system, new),
            players: PairingInput.rescore(parsed.players, old, new)
        }
    end
  end

  # `--forbidden=1,4/2,9,12@3-5`: forbidden groups (`:forbidden_pairs`),
  # added to the file's `XXP`/`260` - `@ROUND` or `@FIRST-LAST` limits one
  # to those rounds, as a `260` does.
  defp with_forbidden_flag(parsed, flags) do
    case groups_of(flags, "forbidden") do
      [] ->
        parsed

      groups ->
        known_ranks!(parsed, groups |> Enum.flat_map(&group_ranks/1), "forbidden")
        update_in(parsed.tournament[:forbidden_pairs], &((&1 || []) ++ groups))
    end
  end

  # `--team-forbidden=1,4/3,11@1-2` and `--team-soft-pairs=...`: the team
  # Swiss's own keep-apart groups, by TEAM number, added to the file's
  # `XXO team-forbidden` / `XXO team-soft-pairs` records. The numbers are
  # checked against the file's teams when the round is paired
  # (`TeamCLI.unknown_team/2`), where the teams are known.
  defp with_team_apart_flags(parsed, flags) do
    [{"team-forbidden", :team_forbidden_pairs}, {"team-soft-pairs", :team_soft_pairs}]
    |> Enum.reduce(parsed, fn {flag, key}, parsed ->
      case groups_of(flags, flag) do
        [] -> parsed
        groups -> update_in(parsed.tournament[key], &((&1 || []) ++ groups))
      end
    end)
  end

  defp group_ranks({ranks, _first, _last}), do: ranks
  defp group_ranks(ranks), do: ranks

  # `--NAME=1,4/2,9,12@3-5`, every occurrence: groups of two or more ranks,
  # each optionally limited to a range of rounds.
  defp groups_of(flags, name) do
    for flag <- flags,
        String.starts_with?(flag, "--#{name}="),
        text = String.trim_leading(flag, "--#{name}="),
        group <- String.split(text, "/") do
      case PairingInput.parse_group(group) do
        {:ok, group} ->
          group

        :error ->
          {what, short} =
            if String.starts_with?(name, "team-"),
              do: {"team numbers", "numbers"},
              else: {"starting ranks", "ranks"}

          refuse(
            "--#{name} takes groups of two or more #{what} separated by /, " <>
              "the #{short} by commas, a group optionally with @ROUND or @FIRST-LAST " <>
              "(e.g. 1,4/2,9,12@3-5), not \"#{text}\""
          )
      end
    end
  end

  defp known_ranks!(parsed, ranks, name) do
    known = MapSet.new(parsed.players, & &1.rank)

    case Enum.find(ranks, &(not MapSet.member?(known, &1))) do
      nil -> :ok
      rank -> refuse("--#{name} names #{rank}, which is not a starting rank in this file")
    end
  end

  # `--acceleration=baku [--baku-group-a=N]`: C.04.7's virtual points worked
  # out here (`Ainalrami.Acceleration`), for a file that does not carry them
  # as `XXA`/`250`. `--virtual-points=1-10:1,1,0.5/11,12:0.5`: any other
  # table, one value per round - an organiser's acceleration, and said to be.
  defp with_acceleration_flags(parsed, flags) do
    baku? =
      case text_option(flags, "acceleration") do
        nil ->
          false

        "baku" ->
          true

        "random" ->
          refuse("--acceleration=random is the generator's (-g); a file is paired with baku")

        other ->
          refuse("unknown acceleration \"#{other}\" - baku")
      end

    last = bounded(option(flags, "baku-group-a"), "baku-group-a", 1)
    table = virtual_points_option(flags)

    cond do
      baku? and table != nil ->
        refuse("--acceleration=baku and --virtual-points are alternatives - give one")

      last != nil and not baku? ->
        refuse("--baku-group-a needs --acceleration=baku")

      (baku? or table != nil) and Acceleration.accelerated?(parsed.players) ->
        refuse(
          "the file already carries virtual points (XXA/250) - " <>
            "--acceleration and --virtual-points are for a file without them"
        )

      baku? ->
        rounds = parsed.tournament[:number_of_rounds]

        if rounds in [nil, 0] do
          refuse(
            "--acceleration=baku needs the tournament's round count, and the file has no " <>
              "142/XXR - add --rounds=N"
          )
        end

        if last, do: known_ranks!(parsed, [last], "baku-group-a")
        %{parsed | players: Acceleration.baku(parsed.players, rounds, group_a_last: last)}

      table != nil ->
        known_ranks!(parsed, Map.keys(table), "virtual-points")

        Log.warn(
          "--virtual-points is an organiser's acceleration, not C.04.7's Baku - this is " <>
            "not a pure FIDE pairing unless the event's own regulations say so"
        )

        %{parsed | players: Acceleration.virtual_points(parsed.players, table)}

      true ->
        parsed
    end
  end

  defp virtual_points_option(flags) do
    case text_option(flags, "virtual-points") do
      nil ->
        nil

      text ->
        bad = fn ->
          refuse(
            "--virtual-points takes RANKS:POINTS entries separated by /, the ranks by " <>
              "commas or as a-b, one value per round by commas (e.g. 1-10:1,1,0.5/11:0.5), " <>
              "not \"#{text}\""
          )
        end

        entries =
          for entry <- String.split(text, "/") do
            case String.split(entry, ":") do
              [ranks, points] ->
                ranks =
                  ranks |> String.split(",", trim: true) |> Enum.flat_map(&round_span(&1, bad))

                points =
                  points
                  |> String.split(",", trim: true)
                  |> Enum.map(fn value ->
                    case Float.parse(String.trim(value)) do
                      {n, ""} when n >= 0 -> n
                      {n, "."} when n >= 0 -> n
                      _ -> bad.()
                    end
                  end)

                if ranks == [] or points == [], do: bad.()
                {ranks, points}

              _ ->
                bad.()
            end
          end

        all = Enum.flat_map(entries, &elem(&1, 0))

        case all -- Enum.uniq(all) do
          [] -> for {ranks, points} <- entries, rank <- ranks, into: %{}, do: {rank, points}
          [rank | _] -> refuse("--virtual-points names #{rank} twice")
        end
    end
  end

  # `--tie-breaks=BH,SB` on `-c` and `-s`: the list to rank by, in place of
  # the file's `202`/`212`. A list that starts with a score (PTS, MPTS,
  # GPTS) is the whole standings order; any other follows the score.
  defp with_tie_break_flag(parsed, flags) do
    # `--cap-rounds=played|announced`: which round count C.07 16.4.2 caps a
    # dummy opponent at (`Ainalrami.Tiebreaks.Event.new/3`).
    parsed =
      case word_option(flags, "cap-rounds", %{"played" => :played, "announced" => :announced}) do
        nil -> parsed
        cap -> put_in(parsed.tournament[:tiebreak_cap_rounds], cap)
      end

    case tie_breaks_option(flags) do
      nil ->
        parsed

      [first | _] = codes when first in ~w(PTS MPTS GPTS) ->
        tournament =
          parsed.tournament |> Map.delete(:tie_breaks) |> Map.put(:standings_order, codes)

        %{parsed | tournament: tournament}

      codes ->
        tournament =
          parsed.tournament |> Map.delete(:standings_order) |> Map.put(:tie_breaks, codes)

        %{parsed | tournament: tournament}
    end
  end

  # `--half-bye=3,7 --zero-bye=12 --full-bye=20`: byes the players asked for
  # in the round about to be paired (a zero-point one is an absence), as a
  # letter in their column or a `240` record says it. `--absent-teams=2,5`:
  # every free player of those teams a zero-point bye, which is how a team
  # sits a round out.
  defp with_bye_flags(parsed, flags) do
    played = max(Trf.rounds_played(parsed.players), Trf.team_rounds(parsed.tournament))

    byes =
      for {name, type} <- [{"half-bye", "H"}, {"zero-bye", "Z"}, {"full-bye", "F"}],
          rank <- ranks_of(flags, name),
          do: {rank, type}

    team_byes =
      case ranks_of(flags, "absent-teams") do
        [] ->
          []

        teams ->
          rosters =
            parsed
            |> Map.get(:teams, [])
            |> Enum.with_index(1)
            |> Map.new(fn {team, index} ->
              {Map.get(team, :number) || index, team.player_ranks}
            end)

          by_rank = Map.new(parsed.players, &{&1.rank, &1})
          named = MapSet.new(byes, &elem(&1, 0))

          for team <- teams,
              rank <-
                Map.get(rosters, team) ||
                  refuse("--absent-teams names team #{team}, which the file does not have"),
              player = by_rank[rank],
              player != nil,
              length(player[:games] || []) <= played,
              not MapSet.member?(named, rank),
              do: {rank, "Z"}
      end

    case byes ++ team_byes do
      [] ->
        parsed

      all ->
        players =
          try do
            PairingInput.request_byes(
              parsed.players,
              all,
              parsed.tournament[:point_system],
              played
            )
          rescue
            e in ArgumentError -> refuse(Exception.message(e))
          end

        %{parsed | players: players}
    end
  end

  # `--NAME=3,7-9`, every occurrence: starting ranks (or team numbers).
  defp ranks_of(flags, name) do
    spans =
      for flag <- flags,
          String.starts_with?(flag, "--#{name}="),
          text = String.trim_leading(flag, "--#{name}="),
          item <- String.split(text, ",") do
        round_span(String.trim(item), fn ->
          refuse(
            "--#{name} takes numbers separated by commas, or a-b for a run of them " <>
              "(e.g. 3,7-9), not \"#{text}\""
          )
        end)
      end

    List.flatten(spans)
  end

  # `--bye-exclude=3,7@4-6+9`: the plain bye exclusion (`:bye_exclusions`),
  # as `{rank, rounds}`.
  defp bye_exclude_option(flags) do
    for flag <- flags,
        String.starts_with?(flag, "--bye-exclude="),
        text = String.trim_leading(flag, "--bye-exclude="),
        item <- String.split(text, ",") do
      case PairingInput.parse_ranked(String.trim(item)) do
        {:ok, rank, rounds} ->
          {rank, rounds}

        :error ->
          refuse(
            "--bye-exclude takes starting ranks separated by commas, each optionally with " <>
              "@ROUNDS (e.g. 3,7@4-6+9), not \"#{text}\""
          )
      end
    end
  end

  # The organiser's options for the round about to be paired - the file's
  # `XXO` records and the flags, the flags added to the records - as
  # `{engine options, bye preferences}`. `[]` and the flags' own preferences
  # for a run with neither, which is every run before the records existed.
  defp organiser_options(parsed, flags, flag_prefs) do
    round = Trf.rounds_played(parsed.players) + 1
    file = PairingInput.organiser_opts(parsed.tournament, round)
    {flag_pairs, flag_position} = soft_flags(flags)
    pairs = (file[:soft_pairs] || []) ++ (flag_pairs || [])

    if flag_position != nil and pairs == [], do: refuse("--soft-position needs --soft-pairs")

    soft =
      if pairs == [],
        do: [],
        else: [
          soft_pairs: pairs,
          soft_position: flag_position || file[:soft_position] || :strong
        ]

    excluded =
      ((file[:bye_exclusions] || []) ++
         PairingInput.bye_exclusions(bye_exclude_option(flags), round))
      |> Enum.uniq()
      |> Enum.sort()

    excluded = if excluded == [], do: [], else: [bye_exclusions: excluded]
    cascade = if "--cascade-order" in flags, do: [cascade_order: true], else: []

    {soft ++ excluded ++ cascade, (file[:bye_preferences] || []) ++ flag_prefs}
  end

  # The team Swiss settings a flag overrides: `--team-type`, `--score` and
  # `--secondary` in place of what the `192` code says.
  defp team_system(parsed, flags) do
    case TeamReplay.system(parsed) do
      {:team, settings} ->
        overrides =
          [
            type: word_option(flags, "team-type", %{"a" => :a, "b" => :b, "none" => :none}),
            score_mode:
              word_option(flags, "score", %{"mp" => :match_points, "gp" => :game_points}),
            use_secondary?: word_option(flags, "secondary", %{"yes" => true, "no" => false})
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        for {key, value} <- overrides do
          Log.detail("#{key}: #{inspect(value)} (command line, in place of the 192 code's)")
        end

        {:team, Map.merge(settings, Map.new(overrides))}

      other ->
        other
    end
  end

  # `--max-upfloater-sets=N` and `--explain-limit=N`: `Ainalrami.TeamPairing`'s
  # options of those names.
  defp team_engine_flags(flags) do
    [
      max_upfloater_sets: bounded(option(flags, "max-upfloater-sets"), "max-upfloater-sets", 1),
      explain_limit: bounded(option(flags, "explain-limit"), "explain-limit", 1)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # What `-c` refuses for the kind of file it was handed - the flags of the
  # other kinds. `-p` and `-x` do the same in `team_or_individual/3`.
  defp check_flag_refusal(system, flags) do
    case system do
      {:team, _} ->
        if flag = given(flags, @individual_only),
          do: "--#{flag} is for an individual tournament, not a team event"

      {:team_round_robin, _} ->
        if flag = given(flags, @individual_only ++ @team_swiss_only),
          do: "--#{flag} is not for a team round robin"

      {:round_robin, _} ->
        if flag = given(flags, @individual_only ++ @team_swiss_only),
          do: "--#{flag} is not for a round robin"

      _ ->
        if flag = given(flags, @team_swiss_only),
          do: "--#{flag} is for a team Swiss, and this file is not one"
    end
  end

  # ---- -x: the rest of `Ainalrami.Alternatives` ----------------------------

  # `--judge=1-5,2-6,3-0`: a whole alternative round (0 for the bye), judged
  # against the round that was paired (`Alternatives.judge/4`).
  defp render_judge(players, pairs, opts, flags) do
    case text_option(flags, "judge") do
      nil ->
        ""

      text ->
        bad = fn ->
          refuse(
            "--judge takes a whole round as WHITE-BLACK pairs separated by commas, 0 for " <>
              "the bye (e.g. 1-5,2-6,3-0), not \"#{text}\""
          )
        end

        alternative =
          for pair <- String.split(text, ",", trim: true) do
            case pair |> String.split("-") |> Enum.map(&Integer.parse(String.trim(&1))) do
              [{w, ""}, {0, ""}] when w >= 1 -> {w, nil}
              [{w, ""}, {b, ""}] when w >= 1 and b >= 1 and w != b -> {w, b}
              _ -> bad.()
            end
          end

        seated = fn round ->
          round |> Enum.flat_map(fn {w, b} -> [w, b] end) |> Enum.reject(&is_nil/1) |> Enum.sort()
        end

        if seated.(alternative) != seated.(pairs) do
          refuse(
            "--judge has to seat the players of the round exactly once each " <>
              "(#{Enum.join(seated.(pairs), ", ")})"
          )
        end

        result = Ainalrami.Alternatives.judge(players, pairs, alternative, opts)

        illegal =
          Enum.map_join(result.violations, "", fn v ->
            [a, b] = v.players
            "  illegal: #{a} vs. #{b} - #{violation_words(v.reason, v)}\n"
          end)

        verdict =
          case result.verdict do
            :identical ->
              "that is the round that was paired"

            {:worse, group, label, actual, alt} ->
              "worse in the #{format_score(group)} bracket: #{label} #{actual} -> #{alt}"

            {:better, group, label, actual, alt} ->
              "scores HIGHER in the #{format_score(group)} bracket on #{label} " <>
                "(#{actual} -> #{alt}) - the engine missed it"

            {:tie, group, pick} ->
              "equal on every criterion in the #{format_score(group)} bracket; the " <>
                "transposition order picks " <>
                case pick do
                  :actual -> "the round that was paired"
                  :alternative -> "the alternative"
                  _ -> "neither"
                end

            {:incomparable, group} ->
              "not comparable rung by rung (the #{format_score(group)} bracket)"
          end

        "\nJudging #{Enum.map_join(alternative, ", ", fn {w, b} -> "#{w}-#{b || "bye"}" end)}\n" <>
          illegal <> "  #{verdict}\n"
    end
  end

  # `--bye-alternatives`: had each other member of the bye's bracket taken
  # it instead (`Alternatives.bye_alternatives/3`).
  defp render_bye_alternatives(players, pairs, opts, flags) do
    if "--bye-alternatives" in flags do
      case Ainalrami.Alternatives.bye_alternatives(players, pairs, with_cap(opts, flags)) do
        nil ->
          "\nBye alternatives\n  the round has no pairing-allocated bye\n"

        %{holder: holder} = result ->
          "\nBye alternatives (the bye went to #{holder})\n" <>
            render_candidates(result, "--alternative-pairs" in flags)
      end
    else
      ""
    end
  end

  # `--float-alternatives`: had each other member of a bracket floated
  # instead of the one who did (`Alternatives.float_alternatives/3`).
  defp render_float_alternatives(players, pairs, opts, flags) do
    if "--float-alternatives" in flags do
      case Ainalrami.Alternatives.float_alternatives(players, pairs, with_cap(opts, flags)) do
        [] ->
          "\nFloat alternatives\n  nobody floated\n"

        entries ->
          Enum.map_join(entries, "", fn entry ->
            "\nFloat alternatives (#{entry.floater} floated out of the " <>
              "#{format_score(entry.group)} bracket)\n" <>
              render_candidates(entry, "--alternative-pairs" in flags)
          end)
      end
    else
      ""
    end
  end

  # `--max-candidates=N|all`: the library's `max_candidates:`, how many
  # candidates one question searches before it says "not worked out"
  # (`Alternatives.max_candidates/0` by default). `all` is OpenPairings'
  # "work out the whole bracket" - one full pairing per candidate, so the
  # wait is the caller's to choose.
  defp with_cap(opts, flags) do
    case text_option(flags, "max-candidates") do
      nil ->
        opts

      "all" ->
        Keyword.put(opts, :max_candidates, :all)

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 ->
            Keyword.put(opts, :max_candidates, n)

          _ ->
            refuse("--max-candidates takes a whole number or all, not \"#{text}\"")
        end
    end
  end

  # `whole?` is `--alternative-pairs`: under each candidate that has a
  # round to show, that round's boards and the played ones they replace.
  # Without the flag the lines are what they were before the engine kept
  # the round, to the byte.
  defp render_candidates(%{skipped: :too_many, count: count}, _whole?),
    do: "  not worked out: #{count} candidates\n"

  defp render_candidates(%{candidates: []}, _whole?), do: "  nobody else in the bracket\n"

  defp render_candidates(%{candidates: candidates}, whole?) do
    Enum.map_join(candidates, "", fn candidate ->
      words =
        case candidate do
          %{outcome: :ineligible, reason: reason} ->
            "not allowed: " <>
              case reason do
                :pairing_bye -> "already had the pairing-allocated bye (C2)"
                :forfeit_win -> "already had a forfeit win (C2)"
                :full_point_bye -> "already had a full-point bye (C2)"
                :organiser_exclusion -> "excluded from the bye by the organiser (not FIDE)"
                :bye_preference -> "kept from the bye by a bye preference (not FIDE)"
                other -> to_string(other)
              end

          %{outcome: :impossible} ->
            "no legal round"

          %{outcome: outcome, differs_at: %{label: label, actual: actual, alternative: alt}}
          when outcome in [:worse, :better] ->
            "#{outcome}: #{label} #{actual} -> #{alt}"

          %{outcome: :tie} ->
            "equal on every criterion; the transposition order decides"

          %{outcome: outcome} ->
            to_string(outcome)
        end

      "  #{candidate.rank}: #{words}\n" <>
        if(whole?, do: render_whole(Map.get(candidate, :alternative)), else: "")
    end)
  end

  defp render_whole(nil), do: ""

  defp render_whole(%{skipped: :too_many_boards, count: count}),
    do: "     alternative: not written out, #{count} boards differ\n"

  defp render_whole(%{pairs: pairs, played: played, unchanged: unchanged} = whole) do
    step =
      case whole.step do
        :transposition -> "; another order of S2"
        :exchange -> "; an exchange between S1 and S2"
        :floater -> "; a different player leaves the bracket"
        nil -> ""
      end

    "     alternative: #{render_boards(pairs)}\n" <>
      "     played:      #{render_boards(played)}\n" <>
      "     #{unchanged} other board#{if unchanged == 1, do: "", else: "s"} unchanged#{step}\n"
  end

  defp render_boards([]), do: "-"

  defp render_boards(pairs),
    do: Enum.map_join(pairs, ", ", fn {w, b} -> if b, do: "#{w}-#{b}", else: "#{w}-bye" end)

  # ---- -s: the standings ----------------------------------------------------

  # `input.trf -s [output]`: the standings by the file's tie-break list
  # (`212`, or the score and then `202`) or `--tie-breaks=` -
  # `Ainalrami.Tiebreaks.rank/3`, which is what `-c` checks the file's own
  # ranks against. A header line, then RANK ID and each value, CRLF like
  # every other list this program writes. Teams (TRF26 `310`) are ranked
  # with the team tie-breaks.
  defp standings(input_path, positional_rest, flags) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text, flags) do
      case standings_list(parsed) do
        nil ->
          Log.error(
            "no tie-break list: the file has none (202/212) - give one with --tie-breaks="
          )

          1

        list ->
          teams? = Map.get(parsed, :teams, []) != []

          ranked =
            if teams? do
              parsed
              |> Ainalrami.Tiebreaks.Team.from_trf()
              |> Ainalrami.Tiebreaks.Team.rank(list, with_dropped: true)
            else
              parsed
              |> standings_event()
              |> Ainalrami.Tiebreaks.rank(list, with_dropped: true)
            end

          case ranked do
            {:ok, rows, dropped} ->
              unless dropped == [] do
                Log.detail("#{Enum.join(dropped, ", ")} dropped - no value for everyone")
              end

              Log.step(
                "Standings of #{length(rows)} #{if teams?, do: "teams", else: "players"} " <>
                  "by #{Enum.join(list, " ")}"
              )

              text = format_standings(rows, list -- dropped)

              case positional_rest do
                [output_path | _] -> write_file!(output_path, text)
                [] -> IO.write(text)
              end

              0

            {:error, reason} ->
              Log.error("standings: #{reason}")
              1
          end
      end
    else
      {:error, :halt} -> 1
    end
  end

  # The individual standings as they stand: the rounds that were PAIRED
  # (`completed_rounds/1`), not every column in the file. A bye granted for
  # a round nobody has paired yet - a TRF26 `240` record, or the engines'
  # `H`/`Z`/`F` written in the pending round's column - is a column too,
  # and `Event.from_trf/2` counts to the longest one. So the bye was in the
  # score `-c` ranked by and `-s` printed, a round before anybody had
  # played it, while the file's places are the standings after its last
  # paired round. Every file that stopped with an announced absence ahead
  # was told its ranks "do not follow" its tie-breaks.
  defp standings_event(parsed) do
    Ainalrami.Tiebreaks.Event.from_trf(parsed,
      rounds: completed_rounds(parsed.players),
      cap_rounds: parsed.tournament[:tiebreak_cap_rounds] || :played
    )
  end

  defp standings_list(parsed) do
    case parsed.tournament do
      %{standings_order: [_ | _] = order} -> order
      %{tie_breaks: [_ | _] = codes} -> ["PTS" | codes]
      _ -> nil
    end
  end

  defp format_standings(rows, list) do
    header = "RANK ID " <> Enum.join(list, " ") <> "\r\n"

    header <>
      Enum.map_join(rows, "", fn row ->
        values =
          Enum.map_join(list, " ", fn code ->
            case row.values[code] do
              nil -> "-"
              value -> format_value(value)
            end
          end)

        "#{row.rank} #{row.id} #{values}\r\n"
      end)
  end

  # Random Tournament Generator (RTG). `ainalrami -g [output.trf]` with
  # optional `--seed=`, `--players=`, `--rounds=`, `--forfeit-pct=`,
  # `--bye-pct=`, `--forbidden-pct=` and `--acceleration=`; writes to
  # stdout when no output path is given.
  defp generate(positional, flags) do
    opts =
      [
        seed: option(flags, "seed"),
        # `Generator.generate/1` raises on these too, but a caller who typed
        # `--players=-5` deserves the usage error rather than the backstop's
        # "unexpected error". The two agree on the bounds on purpose: a
        # roster of at least one, and a round count of at least none.
        players: bounded(option(flags, "players"), "players", 1),
        rounds: bounded(option(flags, "rounds"), "rounds", 0),
        forfeit_pct: option(flags, "forfeit-pct"),
        requested_bye_pct: option(flags, "bye-pct"),
        forbidden_pct: option(flags, "forbidden-pct"),
        acceleration: acceleration_option(flags),
        initial_colour: initial_colour_option(flags),
        # FIDE's checklist axes (VCL4THP v13 Q24-Q32) - see
        # `Ainalrami.Generator`'s "Checklist options".
        ratings: ratings_option(flags),
        results: results_option(flags),
        draw_rate: fraction_option(flags, "draw-rate"),
        full_bye_pct: option(flags, "full-bye-pct"),
        half_bye_pct: option(flags, "half-bye-pct"),
        zero_bye_pct: option(flags, "zero-bye-pct"),
        forfeit_win_pct: option(flags, "forfeit-win-pct"),
        double_forfeit_pct: option(flags, "double-forfeit-pct"),
        odd_results_pct: option(flags, "odd-results-pct"),
        tie_breaks: tie_breaks_option(flags),
        # Q25: what the user left out is drawn, not left off - see
        # `Ainalrami.Generator`'s "Unset options". `--unset=fixed` is the
        # library's own default, for reproducing a corpus run from its seed.
        unset: unset_option(flags),
        unset_chance: bounded_pct(option(flags, "unset-chance"), "unset-chance"),
        # OpenPairings' Swiss match format and pairing by category, written
        # as `XXM` (with CUSTOM_SWISS) and `XXG`.
        match_format: if("--match-format" in flags, do: true),
        groups: generator_groups_option(flags),
        # The spelling of the file, not the tournament: `Trf.serialize/2`'s
        # `dialect:` - `engine` (the default) or `trf26`.
        dialect: dialect_option(flags),
        # `--system=dubov`: every round paired by C.04.4.1, `192 FIDE_DUBOV`.
        system: generator_system_option(flags)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if opts[:match_format] && opts[:groups],
      do: refuse("--match-format and --groups together are not paired - give one")

    if opts[:system] in [:dubov, :burstein] and (opts[:match_format] || opts[:groups]),
      do: refuse("--system=#{opts[:system]} pairs neither the match format nor pairing groups")

    Log.step("Generating a random tournament")
    {text, seed} = Generator.generate(opts)

    # Reported as well as embedded in the file's own tournament name, so a
    # run is reproducible from the console alone if the file is lost.
    Log.detail("seed #{seed}")

    case positional do
      [output_path | _] -> write_file!(output_path, text)
      [] -> IO.write(text)
    end

    0
  end

  # `-g --system=dutch|dubov|burstein`. Dutch is the default and is passed as nothing
  # at all, so every seed generates byte for byte what it always did.
  defp generator_system_option(flags) do
    case text_option(flags, "system") do
      nil -> nil
      "dutch" -> nil
      "dubov" -> :dubov
      "burstein" -> :burstein
      "lim" -> refuse("--system=lim: not built yet - dutch, dubov or burstein")
      other -> refuse("unknown --system \"#{other}\" - dutch, dubov or burstein")
    end
  end

  # `-g --dialect=engine|trf26`: how the Swiss generator spells its file.
  defp dialect_option(flags) do
    case text_option(flags, "dialect") do
      nil -> nil
      "engine" -> :engine
      "trf26" -> :trf26
      other -> refuse("unknown --dialect \"#{other}\" - engine or trf26")
    end
  end

  # The team and round-robin generators have only ever written TRF26 - 310
  # rosters and 192 codes have no other spelling - so there is nothing to
  # choose, and a choice offered would be a choice ignored.
  defp no_dialect!(flags, what) do
    if text_option(flags, "dialect"),
      do: refuse("--dialect is for the Swiss generator; #{what} is always written as TRF26")
  end

  # `-g --team=swiss|roundrobin`: a random team event
  # (`Ainalrami.TeamGenerator`). The individual generator's roster, bye,
  # acceleration and rating options do not apply and are refused; the
  # team's own are read here, and what is left out is drawn from the seed.
  defp generate_team(positional, flags) do
    no_dialect!(flags, "a team event")

    case given(flags, @individual_generator_flags) do
      nil ->
        opts =
          [
            system: team_system_option(flags),
            seed: option(flags, "seed"),
            teams: bounded(option(flags, "teams"), "teams", 2),
            rounds: bounded(option(flags, "rounds"), "rounds", 0),
            boards: bounded(option(flags, "boards"), "boards", 1),
            reserves: bounded(option(flags, "reserves"), "reserves", 0),
            cycles: bounded(option(flags, "cycles"), "cycles", 1),
            type: word_option(flags, "team-type", %{"a" => :a, "b" => :b, "none" => :none}),
            score_mode:
              word_option(flags, "score", %{"mp" => :match_points, "gp" => :game_points}),
            use_secondary?: word_option(flags, "secondary", %{"yes" => true, "no" => false}),
            initial_colour: team_initial_colour(flags),
            match_points: match_points_option(flags),
            pab: word_option(flags, "pab", %{"draw" => :draw, "win" => :win}),
            forfeit_match_points:
              bounded(option(flags, "forfeit-match-points"), "forfeit-match-points", 0),
            board_forfeit_pct: bounded_pct(option(flags, "forfeit-pct"), "forfeit-pct"),
            match_forfeit_pct:
              bounded_pct(option(flags, "match-forfeit-pct"), "match-forfeit-pct"),
            absent_team_pct: bounded_pct(option(flags, "absent-team-pct"), "absent-team-pct"),
            absent_player_pct:
              bounded_pct(option(flags, "absent-player-pct"), "absent-player-pct"),
            out_of_order_pct: bounded_pct(option(flags, "out-of-order-pct"), "out-of-order-pct"),
            draw_rate: fraction_option(flags, "draw-rate"),
            tie_breaks: tie_breaks_option(flags),
            match_format: team_match_format_option(flags)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        Log.step("Generating a random team tournament")
        {text, seed} = TeamGenerator.generate(opts)
        Log.detail("seed #{seed}")

        case positional do
          [output_path | _] -> write_file!(output_path, text)
          [] -> IO.write(text)
        end

        0

      flag ->
        usage_error("--#{flag} is an individual tournament's option, not a team event's")
    end
  end

  # `--match-format` on a team event: a team round robin's (`XXM`); a team
  # Swiss has none in OpenPairings either.
  defp team_match_format_option(flags) do
    cond do
      "--match-format" not in flags -> nil
      team_system_option(flags) == :round_robin -> true
      true -> refuse("--match-format is for a team round robin, not a team Swiss")
    end
  end

  # `-g`'s `--groups=`: a number of groups the field is split into at
  # random, or the groups themselves as `-p` takes them.
  defp generator_groups_option(flags) do
    case text_option(flags, "groups") do
      nil ->
        nil

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 1 -> n
          {_n, ""} -> refuse("--groups takes at least one group, not #{text}")
          _ -> groups_option(flags)
        end
    end
  end

  defp team_system_option(flags) do
    case text_option(flags, "team") do
      v when v in ["swiss", "team-swiss"] -> :swiss
      v when v in ["roundrobin", "round-robin", "rr"] -> :round_robin
      other -> refuse("unknown --team \"#{other}\" - swiss or roundrobin")
    end
  end

  # A word option, refused when it is not one of `words`' keys.
  defp word_option(flags, key, words) do
    case text_option(flags, key) do
      nil ->
        nil

      text ->
        Map.get_lazy(words, String.downcase(text), fn ->
          refuse(
            "unknown --#{key} \"#{text}\" - #{words |> Map.keys() |> Enum.sort() |> Enum.join(" or ")}"
          )
        end)
    end
  end

  # Only when given - an unset initial colour is drawn from the seed.
  defp team_initial_colour(flags) do
    if text_option(flags, "initial-colour") || text_option(flags, "initial-color") do
      case initial_colour_option(flags) do
        "w" -> :white
        "b" -> :black
      end
    end
  end

  # `--match-points=2,1,0`: a win's, a draw's and a loss's match points.
  defp match_points_option(flags) do
    case text_option(flags, "match-points") do
      nil ->
        nil

      text ->
        with [w, d, l] <- String.split(text, ","),
             [{w, ""}, {d, ""}, {l, ""}] <- Enum.map([w, d, l], &Integer.parse(String.trim(&1))),
             true <- w >= d and d >= l and l >= 0 do
          {w, d, l}
        else
          _ ->
            refuse(
              "--match-points takes WIN,DRAW,LOSS as whole numbers, highest first " <>
                "(e.g. 2,1,0), not \"#{text}\""
            )
        end
    end
  end

  # `-p`'s output is not a TRF - it is JaVaFo's bare board list, a count line
  # and one "white black" per pair. `ainalrami live.trf -p live.trf` therefore
  # did not "update" the tournament, it REPLACED it: 361 bytes of roster and
  # history became 13 bytes of board numbers, and the exit code was 0.
  #
  # Refused before anything is read, and on `Path.expand/1` of both sides so
  # `./live.trf` and `live.trf` are the same file here as they are on disk.
  # A caller who genuinely wants to overwrite can write elsewhere and move it,
  # which at least leaves a moment where both files exist.
  #
  # `--proof=FILE` has the same two ways to eat a file, and ate both quietly
  # with exit 0: opened (and truncated) after the input was read, it replaced
  # the tournament with JSON; opened before the board list was written, it
  # was replaced BY the board list, so the proof asked for never existed.
  # Same refusal, same moment - before anything is opened, read or written.
  defp pair_checked(input_path, positional_rest, prefs, flags) do
    output_path = List.first(positional_rest)
    proof_path = text_option(flags, "proof")

    cond do
      output_path && same_file?(output_path, input_path) ->
        usage_error(
          "the output file is the input file (#{input_path}) - " <>
            "-p writes a board list, not a tournament, so this would destroy it"
        )

      proof_path && same_file?(proof_path, input_path) ->
        usage_error(
          "the --proof file (#{proof_path}) is the input file (#{input_path}) - " <>
            "the proof would overwrite the tournament it is proving"
        )

      proof_path && output_path && same_file?(proof_path, output_path) ->
        usage_error(
          "the --proof file (#{proof_path}) is the output file (#{output_path}) - " <>
            "the board list would overwrite the proof"
        )

      true ->
        pair(input_path, positional_rest, prefs, flags)
    end
  end

  # Expanded paths, compared case-blind on Windows and macOS, whose default
  # filesystems think `Live.trf` and `live.trf` are one file. A case-sensitive
  # volume there costs a refusal of two names differing only in case, which
  # is a cheaper mistake than the alternative. Links are not followed.
  defp same_file?(a, b), do: comparable_path(a) == comparable_path(b)

  defp comparable_path(path) do
    expanded = Path.expand(path)

    case :os.type() do
      {:win32, _} -> String.downcase(expanded)
      {:unix, :darwin} -> String.downcase(expanded)
      _ -> expanded
    end
  end

  defp pair(input_path, positional_rest, prefs, flags) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text, flags),
         :dutch <- dubov_route(parsed, flags, prefs),
         :individual <- team_or_individual(parsed, prefs, flags) do
      round_count = report_roster(parsed)

      Log.step("Pairing engine")

      Log.detail(
        if round_count == 0, do: "pairing round 1", else: "pairing round #{round_count + 1}"
      )

      report_extensions(parsed)
      {extra, prefs} = organiser_options(parsed, flags, prefs)
      proof = text_option(flags, "proof")
      proof_file = if proof, do: open_proof(proof)

      extra =
        if proof,
          do: extra ++ [proof: {:stream, &write_proof_line(proof_file, &1)}],
          else: extra

      result =
        try do
          pair_next_round(parsed.players, parsed.tournament, prefs, extra)
        after
          if proof, do: close_proof(proof, proof_file)
        end

      case result do
        {:ok, pairs, _opts} ->
          write_pairs(pairs, positional_rest)
          0

        {:error, :halt} ->
          1
      end
    else
      {:error, :halt} -> 1
      {:swiss, system, parsed, opts} -> pair_system(system, parsed, opts, positional_rest)
      {:team, parsed, system} -> pair_team(parsed, system, positional_rest, flags)
      {:round_robin, parsed, settings} -> pair_round_robin(parsed, settings, positional_rest)
      {:exit, code} -> code
    end
  end

  # `input.trf -x` - pair the next round and then say WHY, bracket by
  # bracket, from the engine's own criteria rather than by reconstructing
  # an argument from the finished boards.
  #
  # This exists because the reasoning was already computed and had no way
  # of being asked for. `Pairing.explain_round/3` has been here since the
  # adjudicator needed it, but only as a library function, so a host
  # application that is not this project's own could pair with the engine
  # and then had to re-derive the explanation from the results. That
  # re-derivation is an inference; this is the thing itself.
  #
  # Two limits, both inherited from `explain_round/3` and both worth
  # printing rather than hiding: it scores the pairs a bracket KEEPS plus
  # those reaching into the next group, so a criterion reads zero when it
  # genuinely did not separate anything; and the rung values are SUMS over
  # a bracket's edges, so they compare across answers only when the edge
  # counts match.
  defp explain(input_path, flags, prefs) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text, flags),
         :dutch <- dubov_route(parsed, flags, prefs),
         :individual <- team_or_individual(parsed, prefs, flags) do
      round_count = report_roster(parsed)
      Log.step("Pairing engine")
      Log.detail("explaining round #{round_count + 1}")
      report_extensions(parsed)
      {extra, prefs} = organiser_options(parsed, flags, prefs)

      case pair_next_round(parsed.players, parsed.tournament, prefs, extra) do
        {:ok, pairs, opts} ->
          explain_pairs(parsed.players, pairs, opts, flags, round_count + 1)

        {:error, :halt} ->
          1
      end
    else
      {:error, :halt} ->
        1

      {:swiss, system, _parsed, _opts} ->
        Log.error(
          "-x explains the Dutch system's criteria ladder, which the #{DubovCLI.name(system)} " <>
            "does not have; not explained (exit code #{@not_replayed})"
        )

        @not_replayed

      {:team, parsed, system} ->
        explain_team(parsed, system, flags)

      {:round_robin, parsed, settings} ->
        explain_round_robin(parsed, settings)

      {:exit, code} ->
        code
    end
  end

  # `-x`'s account of a round already paired. In match format the second
  # leg is not chosen at all, and with pairing groups each group is its own
  # round and is explained as one; `--force` and `--absent` ask about a
  # single pool's alternatives and are refused for either.
  defp explain_pairs(players, pairs, opts, flags, label) do
    round = Trf.rounds_played(players) + 1

    case EventFormat.kind(players, opts) do
      :plain ->
        # The new questions first: one that cannot be answered (a --judge
        # that is not a round) is refused before anything is printed.
        # --force and --absent stay where they were, after the account.
        answers =
          render_judge(players, pairs, opts, flags) <>
            render_bye_alternatives(players, pairs, opts, flags) <>
            render_float_alternatives(players, pairs, opts, flags)

        reports = Pairing.explain_round(players, pairs, opts)
        IO.write(render_cascade(reports))
        IO.write(render_explanation(reports, pairs, label))
        IO.write(render_force(players, pairs, opts, flags))
        IO.write(render_no_show(players, pairs, opts, flags))
        IO.write(answers)
        0

      kind ->
        case given(
               flags,
               ~w(force absent judge bye-alternatives float-alternatives alternative-pairs
                  max-candidates)
             ) do
          nil -> explain_format(kind, pairs, opts, round)
          flag -> usage_error("--#{flag} is for a single pairing pool, not #{format_name(kind)}")
        end
    end
  end

  defp format_name(:second_leg), do: "a match's second leg"
  defp format_name({:groups, _}), do: "pairing groups"

  defp explain_format(:second_leg, pairs, _opts, round) do
    boards = Enum.count(pairs, fn {_w, b} -> b != nil end)

    IO.write(
      "\nRound #{round} - #{boards} board#{plural(boards)}, the second leg of the match " <>
        "begun in round #{round - 1} (match format, XXM)\n" <>
        "  Nothing is chosen: every board of round #{round - 1} is played again, colours " <>
        "reversed.\n" <>
        Enum.map_join(pairs, "", fn
          {w, nil} -> "  #{w}: pairing-allocated bye, as in round #{round - 1}\n"
          {w, b} -> "  #{w} (white) vs. #{b}\n"
        end)
    )

    0
  end

  defp explain_format({:groups, fields}, pairs, opts, round) do
    fields
    |> Enum.with_index(1)
    |> Enum.each(fn {{ranks, field}, index} ->
      members = MapSet.new(ranks)
      own = Enum.filter(pairs, fn {w, _b} -> MapSet.member?(members, w) end)

      IO.write(
        "\n== Pairing group #{index} of #{length(fields)} (XXG): " <>
          "#{length(ranks)} player#{plural(length(ranks))} in the round - " <>
          "#{Enum.join(ranks, ", ")}\n"
      )

      case ranks do
        [only] ->
          IO.write("  #{only}: pairing-allocated bye - nobody else in the group plays\n")

        _ ->
          reports = Pairing.explain_round(field, own, opts)
          IO.write(render_cascade(reports))
          IO.write(render_explanation(reports, own, round))
      end
    end)

    0
  end

  # ---- team events ---------------------------------------------------------

  # Which `-p`/`-x` this file gets: `:individual` (the Dutch system, as
  # always), `{:team, parsed, system}` for a team Swiss or a team round robin
  # (`Ainalrami.TeamCLI`), or `{:exit, code}` - a team system nothing here
  # pairs (exit 2), or an option the team path does not have (a usage
  # error). `TeamReplay.system/1` decides, as it does for `-c`.
  defp team_or_individual(parsed, prefs, flags) do
    case team_system(parsed, flags) do
      {kind, _settings} = system when kind in [:team, :team_round_robin] ->
        cond do
          prefs != [] ->
            {:exit,
             usage_error(
               "the bye preferences are for an individual tournament - a team event's " <>
                 "bye is C.04.6's pairing-allocated bye"
             )}

          flag =
              given(flags, ~w(force absent soft-pairs soft-position groups) ++ @individual_only) ->
            {:exit, usage_error("--#{flag} is for an individual tournament, not a team event")}

          (flag = given(flags, @team_swiss_only)) && kind == :team_round_robin ->
            {:exit, usage_error("--#{flag} is for a team Swiss, not a team round robin")}

          (parsed.tournament[:pairing_groups] || []) != [] ->
            Log.error("XXG pairing groups are for an individual tournament, not a team event")
            {:exit, 1}

          PairingInput.organiser?(parsed.tournament) ->
            Log.error(
              "XXO soft-pair and bye records are for an individual Swiss, not a team event"
            )

            {:exit, 1}

          (parsed.tournament[:forbidden_pairs] || []) != [] ->
            Log.error(player_pairs_misplaced())
            {:exit, 1}

          kind == :team_round_robin and PairingInput.team_apart?(parsed.tournament) ->
            Log.error(team_records_misplaced("a round robin, whose table fixes every match"))
            {:exit, 1}

          true ->
            {:team, parsed, system}
        end

      {:round_robin, settings} ->
        cond do
          prefs != [] ->
            {:exit,
             usage_error(
               "the bye preferences are for a Swiss - a round robin's byes are the table's"
             )}

          flag =
              given(
                flags,
                ~w(force absent lineups boards soft-pairs soft-position) ++
                    @individual_only ++ @team_swiss_only ++ @bye_flags
              ) ->
            {:exit, usage_error("--#{flag} is not for a round robin")}

          PairingInput.organiser?(parsed.tournament) ->
            Log.error("XXO soft-pair and bye records are for a Swiss, not a round robin")
            {:exit, 1}

          PairingInput.team_apart?(parsed.tournament) ->
            Log.error(team_records_misplaced("a round robin"))
            {:exit, 1}

          true ->
            {:round_robin, parsed, settings}
        end

      # A match format the file's own round robin code contradicts: neither
      # schedule can be the one asked for, and a Dutch Swiss is not either.
      {:unreplayable, "XXM" <> _ = reason} ->
        Log.error("not paired - #{reason} (exit code #{@not_replayed})")
        {:exit, @not_replayed}

      {:unreplayable, reason} ->
        if team_code?(parsed) do
          Log.error(
            "not paired - #{reason}. This program pairs C.04.6 team Swiss events and team " <>
              "round robins by the Berger tables (exit code #{@not_replayed})"
          )

          {:exit, @not_replayed}
        else
          individual_only(parsed, flags)
        end

      :individual ->
        individual_only(parsed, flags)
    end
  end

  defp individual_only(parsed, flags) do
    cond do
      flag = given(flags, ~w(lineups boards absent-teams) ++ @team_swiss_only) ->
        {:exit, usage_error("--#{flag} is for a team event, and this file is not one")}

      PairingInput.team_apart?(parsed.tournament) ->
        Log.error(team_records_misplaced("an individual tournament"))
        {:exit, 1}

      true ->
        :individual
    end
  end

  defp team_records_misplaced(what),
    do:
      "XXO team-forbidden and team-soft-pairs records are for a team Swiss, not #{what} - " <>
        "players are kept apart with XXP and XXO soft-pairs"

  # `XXP`/`260` name PLAYERS. The team engine has never read them, and
  # pairing a team round as though a "never pair these" had been honoured
  # is how the individual side once seated two forbidden players together
  # without a word (`Ainalrami.Trf`'s moduledoc) - so it is refused, and
  # the record that does say it for teams is named.
  defp player_pairs_misplaced,
    do:
      "XXP/260 forbidden pairs name players, and a team Swiss pairs teams - " <>
        "keep teams apart with XXO team-forbidden (team numbers)"

  defp team_code?(parsed) do
    case TypeCode.parse(parsed.tournament[:type_code] || "") do
      {:ok, %{team?: true}} -> true
      _ -> false
    end
  end

  # The first of `names` the flags give, as `--name` or `--name=...`.
  defp given(flags, names) do
    Enum.find_value(flags, fn flag ->
      name = name_of(flag)
      if name in names, do: name
    end)
  end

  defp pair_team(parsed, system, positional_rest, flags) do
    report_teams(parsed)

    with {:ok, round} <- team_round(parsed, system, team_engine_flags(flags)),
         {:ok, text} <- team_output(parsed, round, flags) do
      case positional_rest do
        [output_path | _] -> write_file!(output_path, text)
        [] -> IO.write(text)
      end

      0
    else
      {:error, :halt} -> 1
    end
  end

  defp explain_team(parsed, system, flags) do
    report_teams(parsed)

    case team_round(parsed, system, [explain: true] ++ team_engine_flags(flags)) do
      {:ok, round} ->
        IO.write(TeamCLI.render_explanation(round))
        0

      {:error, :halt} ->
        1
    end
  end

  defp team_round(parsed, system, opts) do
    Log.step("Pairing engine")

    case TeamCLI.pair(parsed, system, opts) do
      {:ok, round} ->
        TeamCLI.report(round)
        {:ok, round}

      {:error, message} ->
        Log.error(message)
        {:error, :halt}
    end
  end

  defp team_output(parsed, round, flags) do
    pairs = TeamCLI.format_pairs(round)

    if "--lineups" in flags do
      case TeamCLI.format_lineups(parsed, round, bounded(option(flags, "boards"), "boards", 1)) do
        {:ok, boards} ->
          {:ok, pairs <> boards}

        {:error, message} ->
          Log.error(message)
          {:error, :halt}
      end
    else
      {:ok, pairs}
    end
  end

  # ---- individual round robins ---------------------------------------------

  defp pair_round_robin(parsed, settings, positional_rest) do
    Log.step("Pairing engine")
    Log.detail(RoundRobin.describe(settings))

    case RoundRobin.next_round(parsed, settings) do
      {:ok, round, boards, free} ->
        Log.detail("pairing round #{round} of the Berger table")
        for {w, b} <- boards, do: Log.detail(board_description(w, b))
        for f <- free, do: Log.detail("##{f} - free round (Berger table)")
        text = RoundRobin.format(boards, free)

        case positional_rest do
          [output_path | _] -> write_file!(output_path, text)
          [] -> IO.write(text)
        end

        0

      {:error, reason} ->
        Log.error(round_robin_refusal(reason))
        1
    end
  end

  defp explain_round_robin(parsed, settings) do
    case RoundRobin.next_round(parsed, settings) do
      {:ok, round, boards, free} ->
        IO.write(
          "\nRound #{round} - #{length(boards)} board#{plural(length(boards))}, round #{round} " <>
            "of the Berger table for #{length(parsed.players)} players\n" <>
            "  #{RoundRobin.describe(settings)}\n" <>
            "  Nothing is chosen: the table fixes every game and its colours.\n" <>
            Enum.map_join(boards, "", fn {w, b} -> "  #{w} (white) vs. #{b}\n" end) <>
            Enum.map_join(free, "", &"  #{&1}: free round\n")
        )

        0

      {:error, reason} ->
        Log.error(round_robin_refusal(reason))
        1
    end
  end

  defp round_robin_refusal({:all_rounds_paired, total}),
    do: "every round of the Berger table is paired (#{total})"

  defp round_robin_refusal(:too_few_players), do: "a round robin needs at least two players"

  # `-c` on an individual round robin: every round against the table,
  # colours included; a scheduled game the file has nothing for is
  # reported, not counted as a difference.
  defp check_round_robin(parsed, settings) do
    rounds = RoundRobin.paired_rounds(parsed)

    if rounds == 0 do
      Log.warn("no completed rounds to check")
      0
    else
      Log.step(
        "Checking #{rounds} round(s) - #{RoundRobin.describe(settings)}, " <>
          "#{length(parsed.players)} players"
      )

      results =
        Enum.map(1..rounds, fn round ->
          check = RoundRobin.check_round(parsed, round, settings)
          report_round_robin_check(check, round)
        end)

      finish_check(parsed, results, rounds)
    end
  end

  defp report_round_robin_check(check, round) do
    unless check.missing == [] do
      Log.warn("round #{round}: no record of the scheduled game(s) #{inspect(check.missing)}")
    end

    case check.result do
      :ok ->
        Log.detail("round #{round}: matches the Berger table")
        :ok

      :colours ->
        Log.warn(
          "round #{round}: DIFFERS in colours only - reversed against the Berger table in " <>
            "#{length(check.differing)} game(s): #{inspect(check.differing)}"
        )

        :differs

      :differs ->
        Log.warn("round #{round}: DIFFERS from the Berger table")
        Log.warn("  file:   #{inspect(Enum.sort(check.file))}")
        Log.warn("  table:  #{inspect(Enum.sort(check.engine))}")
        :differs

      :beyond ->
        Log.warn("round #{round}: the Berger table has no such round")
        :differs
    end
  end

  # `-g --roundrobin`: an individual round robin (`Ainalrami.RoundRobinGenerator`).
  @round_robin_generator_flags ~w(seed players rounds cycles forfeit-pct draw-rate
                                  rating-range tie-breaks match-format groups)

  defp generate_round_robin(positional, flags) do
    no_dialect!(flags, "a round robin")

    case Enum.find(flags, fn f ->
           String.starts_with?(f, "--") and f != "--roundrobin" and
             name_of(f) not in (@round_robin_generator_flags ++ ~w(quiet debug))
         end) do
      nil ->
        opts =
          [
            seed: option(flags, "seed"),
            players: bounded(option(flags, "players"), "players", 2),
            rounds: bounded(option(flags, "rounds"), "rounds", 0),
            cycles: bounded(option(flags, "cycles"), "cycles", 1),
            forfeit_pct: bounded_pct(option(flags, "forfeit-pct"), "forfeit-pct"),
            draw_rate: fraction_option(flags, "draw-rate"),
            rating_range:
              case ratings_option(flags) do
                {:range, low, high} -> {low, high}
                nil -> nil
                _ -> refuse("--roundrobin takes --rating-range only")
              end,
            tie_breaks: tie_breaks_option(flags),
            match_format: if("--match-format" in flags, do: true),
            groups: generator_groups_option(flags)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        if opts[:match_format] && opts[:cycles] not in [nil, 1],
          do:
            refuse(
              "--match-format plays one table as two-game matches, not --cycles=#{opts[:cycles]}"
            )

        Log.step("Generating a random round robin")
        {text, seed} = RoundRobinGenerator.generate(opts)
        Log.detail("seed #{seed}")

        case positional do
          [output_path | _] -> write_file!(output_path, text)
          [] -> IO.write(text)
        end

        0

      flag ->
        usage_error("--#{name_of(flag)} is not an option of -g --roundrobin")
    end
  end

  defp report_teams(parsed) do
    Log.detail("#{length(parsed.teams)} teams, #{length(parsed.players)} players")
  end

  defp render_explanation(reports, pairs, round_number) do
    boards = Enum.count(pairs, fn {_w, b} -> b != nil end)

    header =
      "
Round #{round_number} - #{boards} board#{plural(boards)} over " <>
        "#{length(reports)} bracket#{plural(length(reports))}
"

    header <> Enum.map_join(Enum.with_index(reports, 1), "", &render_bracket/1)
  end

  # The float cascade: how the brackets fed each other, top to bottom, in
  # one line per bracket. The per-bracket detail below it says the same
  # thing at length; this is the shape of the round at a glance.
  defp render_cascade(reports) do
    lines =
      Enum.map(reports, fn report ->
        residents = Enum.join(report.residents, ", ")
        arrivals = if report.mdps == [], do: "", else: "  + #{Enum.join(report.mdps, ", ")}"
        paired = Enum.map_join(report.pairs, ", ", fn {a, b} -> "#{a}-#{b}" end)

        outcome =
          case {report.pairs, report.floats} do
            {[], []} -> "-"
            {[], floats} -> "nobody pairs; #{Enum.join(floats, ", ")} float down"
            {_, []} -> paired
            {_, floats} -> "#{paired}; #{Enum.join(floats, ", ")} float down"
          end

        "  #{String.pad_leading(format_score(report.group), 5)}  " <>
          "#{String.pad_trailing(residents <> arrivals, 28)} -> #{outcome}\n"
      end)

    "\nFloat cascade\n" <> Enum.join(lines) <> "\n"
  end

  # `--force=A-B`: the best round in which A and B meet, and what it costs.
  defp render_force(players, pairs, opts, flags) do
    case pair_option(flags, "force") do
      nil ->
        ""

      {a, b} ->
        result = Ainalrami.Alternatives.force_pair(players, pairs, a, b, opts)

        body =
          case result do
            %{outcome: :illegal, reason: %{reason: why} = v} ->
              "  they cannot meet: #{violation_words(why, v)}\n"

            %{outcome: :illegal} ->
              "  they cannot meet: no legal round seats them together\n"

            %{outcome: :impossible, reason: reason} ->
              "  no legal round contains that pair: #{reason}\n"

            %{outcome: :same} ->
              "  that is the round that was paired\n"

            %{outcome: outcome, differs_at: at, changed: changed, pairs: alt} ->
              verdict =
                case outcome do
                  :worse ->
                    "legal, but worse: #{at.label} #{at.actual} -> #{at.alternative}"

                  :better ->
                    "scores HIGHER on #{at.label} (#{at.actual} -> #{at.alternative}) - the engine missed it"

                  :tie ->
                    "equal on every criterion; the transposition order decides"

                  :incomparable ->
                    "not comparable rung by rung"
                end

              "  #{verdict}\n  #{changed} board#{plural(changed)} would change\n" <>
                Enum.map_join(alt, "", fn {w, k} -> "    #{w} (white) vs. #{k || "bye"}\n" end)
          end

        "\nForcing #{a} vs. #{b}\n" <> body
    end
  end

  # `--absent=N`: N did not turn up. The least disruptive legal fixes.
  defp render_no_show(players, pairs, opts, flags) do
    case option(flags, "absent") do
      nil ->
        ""

      absent ->
        case Ainalrami.Alternatives.no_show(players, pairs, absent, opts) do
          %{needed: false, why: :had_bye} ->
            "\nIf #{absent} does not turn up\n  nothing to fix - they held the bye\n"

          %{needed: false} ->
            "\nIf #{absent} does not turn up\n  nothing to fix - they were not seated\n"

          %{opponent: opponent, options: options, full_repair: full} ->
            listed =
              Enum.map_join(options, "", fn option ->
                who =
                  case option.affected do
                    [] -> "nobody else moves"
                    ranks -> "also moves #{Enum.join(ranks, ", ")}"
                  end

                cost =
                  case option do
                    %{outcome: :same} ->
                      "this is the best round"

                    %{outcome: :worse, differs_at: at} ->
                      "costs #{at.label} (#{at.actual} -> #{at.alternative})"

                    %{outcome: :tie} ->
                      "equal to the best round on every criterion"

                    %{outcome: other} ->
                      to_string(other)
                  end

                "  #{who}: #{cost}\n" <>
                  Enum.map_join(option.pairs -- pairs, "", fn {w, k} ->
                    "      #{w} (white) vs. #{k || "bye"}\n"
                  end)
              end)

            "\nIf #{absent} does not turn up (opponent #{opponent})\n" <>
              listed <>
              "  full re-pair moves #{length(full.affected)} other player#{plural(length(full.affected))}\n"
        end
    end
  end

  defp violation_words(:rematch, %{round: round}), do: "met in round #{round}"
  defp violation_words(:colour, %{colour: colour}), do: "both absolutely due #{colour}"
  defp violation_words(:forbidden, _v), do: "the arbiter forbade this pairing"
  defp violation_words(other, _v), do: to_string(other)

  # `--force=2-9`: two starting ranks joined by a dash.
  defp pair_option(flags, key) do
    prefix = "--#{key}="

    case Enum.find(flags, &String.starts_with?(&1, prefix)) do
      nil ->
        nil

      flag ->
        value = String.trim_leading(flag, prefix)

        case String.split(value, "-") do
          [a, b] ->
            case {Integer.parse(a), Integer.parse(b)} do
              {{x, ""}, {y, ""}} when x != y -> {x, y}
              _ -> refuse("--#{key} takes two starting ranks as A-B, not \"#{value}\"")
            end

          _ ->
            refuse("--#{key} takes two starting ranks as A-B, not \"#{value}\"")
        end
    end
  end

  defp render_bracket({report, index}) do
    """

    Bracket #{index} · score #{format_score(report.group)} · #{length(report.order)} player#{plural(length(report.order))}
    #{row("moved down", report.mdps)}
    #{row("residents", report.residents)}
    #{row("paired", Enum.map(report.pairs, fn {a, b} -> "#{a}-#{b}" end))}
    #{row("floats down", report.floats)}
    #{render_rungs(report)}
    """
  end

  defp row(label, []), do: "  #{String.pad_trailing(label, 12)} -"
  defp row(label, values), do: "  #{String.pad_trailing(label, 12)} #{Enum.join(values, ", ")}"

  # Only the rungs that actually scored. A zero means the criterion did not
  # separate anything in this bracket, and printing nineteen of them buries
  # the two that did.
  defp render_rungs(%{rungs: rungs, edge_count: edges}) do
    scored = Enum.reject(rungs, fn {_label, value} -> value == 0 end)

    head =
      "  #{String.pad_trailing("criteria", 12)} #{length(scored)} of #{length(rungs)} scored, " <>
        "over #{edges} edge#{plural(edges)}"

    case scored do
      [] ->
        head <> "
                 (nothing separated this bracket)"

      _ ->
        head <>
          Enum.map_join(scored, "", fn {label, value} ->
            "
                 #{String.pad_trailing(label, 30)} #{value}"
          end)
    end
  end

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 1)
  defp format_score(score), do: to_string(score)

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # No legal pairing can mean the field has genuinely run out of legal
  # opponents (bbpPairings' own `NoValidPairingException` - see
  # `Ainalrami.Pairing.NoValidPairingError`'s doc) rather than a crash. That
  # matches how JaVaFo itself reports it: an empty pairing, not a stack
  # trace.
  #
  # With bye preferences the round is paired by `ByePreference.pair/2`, the
  # departure from FIDE is announced on stderr, and what each preference did
  # is reported; the options handed back are the resolved ones, so `-x`
  # explains the round under the rules it was actually paired by.
  defp pair_next_round(players, tournament, prefs, extra) do
    opts = pairing_opts(tournament) ++ extra

    if extra[:soft_pairs] do
      Log.warn(
        "soft pairs are an organiser's wish, not FIDE's - a round they change is not a " <>
          "pure FIDE pairing, and a FIDE checker replaying the file will not reproduce it"
      )
    end

    if extra[:bye_exclusions] do
      Log.warn(
        "bye exclusions are an organiser's rule, not FIDE's - this is not a pure FIDE " <>
          "pairing, and a FIDE checker replaying the file will not reproduce a round they change"
      )
    end

    cond do
      format?(opts) -> pair_in_format(players, opts, prefs)
      prefs == [] -> {:ok, Pairing.pair_next_round(players, opts), opts}
      true -> pair_with_preferences(players, opts, prefs)
    end
  rescue
    e in Pairing.NoValidPairingError ->
      Log.error("no legal pairing exists for this round: #{Exception.message(e)}")
      {:error, :halt}

    e in EventFormat.Error ->
      Log.error(Exception.message(e))
      {:error, :halt}

    # A "must get the bye" for a player C2 rules out: the round is not
    # paired, and the message names the player and their earlier bye.
    e in ByePreference.RefusedError ->
      Log.error(Exception.message(e))
      {:error, :halt}
  end

  # Match format or pairing groups (`Ainalrami.EventFormat`): the round as
  # OpenPairings pairs it in that format. Bye preferences are resolved
  # group by group by the engine itself, without `ByePreference`'s
  # per-preference account.
  defp pair_in_format(players, opts, prefs) do
    case EventFormat.kind(players, opts) do
      :second_leg ->
        Log.detail("the second leg of a match: the round before, colours reversed (XXM)")

        unless prefs == [],
          do: Log.warn("bye preferences: not applied - a second leg copies the first")

      {:groups, fields} ->
        Log.detail(
          "#{length(fields)} pairing group(s), each paired on its own (XXG): " <>
            Enum.map_join(fields, " / ", fn {ranks, _} -> Enum.join(ranks, ",") end)
        )

      :plain ->
        Log.detail("the first leg of a match: paired by the Dutch system (XXM)")
    end

    opts = if prefs == [], do: opts, else: opts ++ [bye_preferences: prefs]

    unless prefs == [] do
      Log.warn(
        "bye preferences are an organiser's rule, not FIDE's - this is not a pure FIDE " <>
          "pairing, and a FIDE checker replaying the file will not reproduce a round they change"
      )
    end

    {:ok, EventFormat.pair_next_round(players, opts), opts}
  end

  # `--proof=FILE` (`Ainalrami.Proof`): the proof of every round the
  # pairing produced - one, or one per pairing group - as JSON Lines,
  # written as the engine records it rather than gathered first: a large
  # field's proof runs to hundreds of megabytes, and the weights are packed
  # criteria of 50-170 digits, so a `.gz` name gets it gzipped on the way
  # (about 15x smaller). A round paired without the Dutch engine (a second
  # leg, a round robin) has no matching to prove and gets none.
  defp open_proof(path) do
    modes = [:write, :binary] ++ if(String.ends_with?(path, ".gz"), do: [:compressed], else: [])
    Process.put(:ainalrami_cli_proof_rounds, 0)
    File.open!(path, modes)
  end

  defp write_proof_line(file, line) do
    if String.contains?(line, ~s("type":"round")),
      do: Process.put(:ainalrami_cli_proof_rounds, Process.get(:ainalrami_cli_proof_rounds) + 1)

    IO.binwrite(file, line)
  end

  defp close_proof(path, file) do
    File.close(file)
    rounds = Process.delete(:ainalrami_cli_proof_rounds) || 0

    if rounds == 0 do
      Log.warn(
        "--proof: no round here was paired by the Dutch engine, so there is nothing to prove"
      )
    end

    Log.detail("proof: #{rounds} round(s) written to #{path}")
  end

  defp format?(opts), do: opts[:match_format] == true or (opts[:groups] || []) != []

  defp pair_with_preferences(players, opts, prefs) do
    Log.warn(
      "bye preferences are an organiser's rule, not FIDE's - this is not a pure FIDE " <>
        "pairing, and a FIDE checker replaying the file will not reproduce a round they change"
    )

    {pairs, report} = ByePreference.pair(players, opts ++ [bye_preferences: prefs])

    for {outcome, line} <- Enum.zip(report.outcomes, ByePreference.describe(report)) do
      if outcome.outcome == :honoured,
        do: Log.detail("bye preference: #{line}"),
        else: Log.warn("bye preference: #{line}")
    end

    if report.moved do
      Log.warn(
        "the bye preferences changed this round: without them the bye goes to " <>
          if(report.fide_bye, do: "##{report.fide_bye}", else: "nobody")
      )
    end

    {:ok, pairs, Keyword.put_new(report.opts, :bye_passed_over, false)}
  end

  # Everything the engine needs that lives on the tournament rather than on
  # a player. Acceleration is absent because it doesn't belong here: `XXA`
  # is per-player and rides along on the player maps themselves.
  defp pairing_opts(tournament) do
    [
      expected_rounds: tournament[:number_of_rounds],
      forbidden_pairs: tournament[:forbidden_pairs],
      # What a result is worth (`BBW`/`BBD`/`BBL`/`BBZ`/`BBF`/`BBU`, or a
      # `162` line). Absent from a file means the standard system, which is
      # what `Pairing` defaults to - but when a file DOES say, the scores
      # every bracket is built from depend on it.
      point_system: tournament[:point_system],
      # Article 5.1's drawing of lots. `Trf` has read `152` since
      # 2026-08-17 but the CLI never forwarded it, so `-p` and `-c` fell
      # back to inferring the draw from round one - which works for a file
      # that HAS a round one and is simply wrong for a fresh roster, where
      # there is nothing to infer from and the engine defaults to White.
      #
      # So an arbiter who drew Black, recorded it, and asked for round one
      # got White pairings from a file that said otherwise. `nil` here is
      # harmless: the engine falls through to inference and then to White,
      # exactly as before.
      initial_colour: tournament[:initial_colour]
    ] ++ format_opts(tournament)
  end

  # The match format and the pairing groups (`XXM`/`XXG` or their flags),
  # for `Ainalrami.EventFormat` - only when the file or the command line
  # asks for them, so every other round is paired with exactly the options
  # it always was.
  defp format_opts(tournament) do
    match = if tournament[:match_format] == true, do: [match_format: true], else: []

    groups =
      case tournament[:pairing_groups] do
        [_ | _] = groups -> [groups: groups]
        _ -> []
      end

    match ++ groups
  end

  # An arbiter's exclusions and any acceleration are reported explicitly.
  # These were silently discarded until this engine learned to read them,
  # and a silent "no `XXP` line here after all" is exactly the failure the
  # trace should make impossible to miss.
  defp report_extensions(parsed) do
    report_format(parsed)

    for group <- parsed.tournament[:forbidden_pairs] || [] do
      Log.detail("forbidden pairing: #{describe_group(group)}")
    end

    for player <- parsed.players, player[:accelerations] not in [nil, []] do
      Log.detail(
        "##{player.rank} acceleration: " <>
          Enum.map_join(
            player[:accelerations],
            " ",
            &:erlang.float_to_binary(&1 / 1, decimals: 1)
          )
      )
    end
  end

  defp report_format(parsed) do
    if parsed.tournament[:match_format] == true do
      Log.detail(
        "match format (XXM): odd rounds paired, each even round the round before with the " <>
          "colours reversed"
      )
    end

    for {group, index} <- Enum.with_index(parsed.tournament[:pairing_groups] || [], 1) do
      Log.detail("pairing group #{index} (XXG): #{join_ids(group)}")
    end

    for group <- parsed.tournament[:soft_pairs] || [] do
      Log.detail("soft pair (XXO): #{describe_group(group)}")
    end

    for entry <- parsed.tournament[:bye_exclusions] || [] do
      {rank, rounds} = if is_tuple(entry), do: entry, else: {entry, :all}
      Log.detail("bye exclusion (XXO): ##{PairingInput.format_ranked(rank, rounds)}")
    end

    for pref <- parsed.tournament[:bye_preferences] || [] do
      rounds = if tuple_size(pref) == 3, do: elem(pref, 2), else: :all

      Log.detail(
        "bye preference (XXO): ##{PairingInput.format_ranked(elem(pref, 0), rounds)} " <>
          "#{elem(pref, 1)}"
      )
    end
  end

  # A forbidden-pair group is EITHER a bare list of starting ranks (`XXP`)
  # or the round-limited `{ids, first, last}` a `260` line parses into. The
  # trace joined the group directly, so a `260` reached `Enum.map_join/3`
  # with a tuple and took `-p` and `-x` down with "protocol Enumerable not
  # implemented for Tuple" - on a file the engine itself pairs correctly.
  # `Trf` has its own private `group_ids/1` for exactly this; the shape is
  # part of the parse result's public surface, so the CLI matches it here
  # rather than reaching into the parser.
  defp describe_group({ids, first, last}) when is_list(ids) do
    "#{join_ids(ids)} (rounds #{first}-#{last})"
  end

  defp describe_group(ids) when is_list(ids), do: join_ids(ids)
  defp describe_group(other), do: inspect(other)

  defp join_ids(ids), do: Enum.map_join(ids, " / ", &"##{&1}")

  # Pairings Checker (FPC). Replays a completed tournament round by round,
  # re-pairing each round from the state that preceded it and diffing
  # against the pairing the file actually records.
  #
  # This mirrors what bbpPairings' own `-c` does (`tournament/checker.cpp`)
  # and it is worth being precise about what that means: a checker is NOT
  # an independent verifier of the rules. It clears the matches, replays,
  # and calls the SAME pairing engine to decide what each round should
  # have been. "Correct" here means "what this engine would have paired",
  # so a disagreement is a difference, not a proof of illegality - the
  # file may hold a perfectly legal pairing that this engine wouldn't pick.
  #
  # Composition (who plays whom) is reported as an error. Colours are
  # reported separately and never as an error, because Article 5.1 leaves
  # the first colour to a drawing of lots and this engine's convention is
  # its own - see `Ainalrami.Pairing.pair_round_one/1`.
  #
  # A team event is replayed team against team (`check_team/2`), and a
  # file whose system this checker cannot replay - a round robin,
  # Scheveningen, Schiller, knockout, a Swiss other than the Dutch system,
  # a custom or accelerated team event, a Baku file without its virtual
  # points - is said to be one and exits `@not_replayed`
  # (`check_unreplayable/2`). `Ainalrami.TeamReplay.system/1` decides which,
  # from the `192` code as `Ainalrami.TypeCode` reads FIDE's table.
  defp check(input_path, flags) do
    Log.step("Loading #{input_path}")

    with {:ok, text} <- read_input(input_path),
         {:ok, parsed} <- parse_input(text, flags),
         :dutch <- dubov_route(parsed, flags, []) do
      groups? = (parsed.tournament[:pairing_groups] || []) != []
      organiser? = PairingInput.organiser?(parsed.tournament)
      team_apart? = PairingInput.team_apart?(parsed.tournament)
      player_pairs? = (parsed.tournament[:forbidden_pairs] || []) != []
      system = team_system(parsed, flags)
      refusal = check_flag_refusal(system, flags)

      case system do
        _ when refusal != nil ->
          usage_error(refusal)

        {kind, _settings} when kind in [:team, :team_round_robin] and groups? ->
          Log.error("XXG pairing groups are for an individual tournament, not a team event")
          1

        {kind, _settings}
        when kind in [:team, :team_round_robin, :round_robin] and organiser? ->
          Log.error(
            "XXO soft-pair and bye records are for an individual Swiss, not this file's system"
          )

          1

        {:team, _settings} when player_pairs? ->
          Log.error(player_pairs_misplaced())
          1

        {kind, _settings} when kind != :team and team_apart? ->
          Log.error(team_records_misplaced("this file's system"))
          1

        kind when kind == :individual and team_apart? ->
          Log.error(team_records_misplaced("an individual tournament"))
          1

        {:unreplayable, "XXM" <> _ = reason} ->
          Log.warn("rounds: not replayed - #{reason} (exit code #{@not_replayed})")
          @not_replayed

        :individual ->
          check_individual(parsed)

        {:team, settings} ->
          check_team(parsed, settings, flags)

        {:team_round_robin, settings} ->
          check_team_round_robin(parsed, settings)

        {:round_robin, settings} ->
          check_round_robin(parsed, settings)

        {:unreplayable, reason} ->
          check_unreplayable(parsed, reason)
      end
    else
      {:error, :halt} -> 1
      {:swiss, system, parsed, opts} -> check_system(system, parsed, opts)
      {:exit, code} -> code
    end
  end

  # ---- the Dubov and Burstein systems ---------------------------------------

  # Which system an individual file is paired by (`Ainalrami.DubovCLI.system/2`):
  # `:dutch` to carry on as always, `{:swiss, system, parsed, opts}` for
  # `:dubov` or `:burstein`, or `{:exit, code}`. A Dutch file sees no change
  # but the refusal of `--provisional-rating`, which nothing else reads.
  defp dubov_route(parsed, flags, prefs) do
    case DubovCLI.system(parsed, text_option(flags, "system")) do
      {:refuse, 2, message} ->
        Log.error("not paired - #{message} (exit code #{@not_replayed})")
        {:exit, @not_replayed}

      {:refuse, _code, message} ->
        {:exit, usage_error(message)}

      :dutch ->
        if text_option(flags, "provisional-rating"),
          do:
            {:exit, usage_error("--provisional-rating is for the Dubov system (--system=dubov)")},
          else: :dutch

      system ->
        system_settings(system, parsed, flags, prefs)
    end
  end

  defp system_settings(system, parsed, flags, prefs) do
    t = parsed.tournament
    name = DubovCLI.name(system)

    cond do
      prefs != [] ->
        {:exit, usage_error("bye preferences are an organiser's rule the #{name} does not have")}

      flag =
          given(
            flags,
            DubovCLI.refused_flags() ++ @team_swiss_only ++ ~w(lineups boards absent-teams)
          ) ->
        {:exit, usage_error("--#{flag} is not for the #{name}")}

      PairingInput.organiser?(t) ->
        Log.error("XXO soft-pair and bye records are the organiser's, not the #{name}'s")
        {:exit, 1}

      (t[:pairing_groups] || []) != [] or t[:match_format] == true ->
        Log.error("XXG pairing groups and the XXM match format are not paired by the #{name}")
        {:exit, 1}

      system == :burstein ->
        if text_option(flags, "provisional-rating"),
          do:
            {:exit,
             usage_error(
               "--provisional-rating is for the Dubov system; Burstein reads no ratings"
             )},
          else: {:swiss, :burstein, parsed, DubovCLI.burstein_opts(t)}

      true ->
        case DubovCLI.provisional_flag(text_option(flags, "provisional-rating")) do
          {:error, message} -> {:exit, usage_error(message)}
          provisional -> {:swiss, :dubov, parsed, DubovCLI.opts(t, provisional)}
        end
    end
  end

  defp pair_system(system, parsed, opts, positional_rest) do
    round_count = report_roster(parsed)
    Log.step("Pairing engine")

    Log.detail(
      "#{DubovCLI.title(system)}, round #{round_count + 1}#{seeding_note(system, opts, round_count + 1)}"
    )

    case DubovCLI.pair(system, parsed.players, opts) do
      {:ok, pairs} ->
        write_pairs(pairs, positional_rest)
        0

      {:error, message} ->
        Log.error(message)
        1
    end
  end

  defp seeding_note(:burstein, opts, round) do
    rounds = opts[:expected_rounds]

    if is_integer(rounds) and round <= Ainalrami.Burstein.seeding_rounds(rounds),
      do: " - a seeding round, paired by the Dutch system (1.6)",
      else: ""
  end

  defp seeding_note(_system, _opts, _round), do: ""

  # `-c` on a Dubov or Burstein file: every round re-paired from the state
  # before it. Unlike the Dutch replay a colour difference IS a difference -
  # Article 5.2 decides every colour from the initial colour, which the file
  # gives (152) or round 1 shows.
  defp check_system(system, parsed, opts) do
    rounds = completed_rounds(parsed.players)

    opts =
      if opts[:initial_colour],
        do: opts,
        else: Keyword.put(opts, :initial_colour, infer_initial(system, parsed, opts))

    if rounds == 0 do
      Log.warn("no completed rounds to check")
      0
    else
      Log.step("Checking #{rounds} round(s) - #{DubovCLI.title(system)}")
      Log.detail("initial colour #{opts[:initial_colour]}")

      results =
        Enum.map(1..rounds, fn round ->
          before = state_before_round(parsed.players, round, opts[:point_system])
          actual = recorded_pairs(parsed.players, round)

          case DubovCLI.pair(system, before, opts) do
            {:ok, expected} ->
              cond do
                Enum.sort(expected) == Enum.sort(actual) ->
                  Log.detail("round #{round}: matches")
                  :ok

                composition(expected) == composition(actual) ->
                  Log.warn("round #{round}: DIFFERS in colours (5.2)")
                  Log.warn("  file:   #{inspect(Enum.sort(actual))}")
                  Log.warn("  engine: #{inspect(Enum.sort(expected))}")
                  :differs

                true ->
                  Log.warn("round #{round}: DIFFERS")
                  Log.warn("  file:   #{inspect(Enum.sort(actual))}")
                  Log.warn("  engine: #{inspect(Enum.sort(expected))}")
                  :differs
              end

            {:error, message} ->
              Log.warn("round #{round}: #{message}")
              :differs
          end
        end)

      finish_check(parsed, results, rounds)
    end
  end

  defp infer_initial(:dubov, parsed, opts),
    do: Dubov.infer_initial_colour(parsed.players, opts[:point_system])

  defp infer_initial(:burstein, parsed, _opts),
    do: Ainalrami.Burstein.infer_initial_colour(parsed.players)

  defp check_individual(parsed) do
    report_type_code(parsed)
    report_format(parsed)

    if PairingInput.organiser?(parsed.tournament) do
      Log.warn(
        "the file carries the organiser's own rules (XXO soft pairs and bye settings), " <>
          "which are not FIDE's - every round is replayed WITH them, so this is not a pure " <>
          "FIDE check, and a FIDE checker replaying the file will not reproduce a round " <>
          "they changed"
      )
    end

    rounds = completed_rounds(parsed.players)

    if rounds == 0 do
      Log.warn("no completed rounds to check")
      0
    else
      Log.step("Checking #{rounds} round(s)")

      results = Enum.map(1..rounds, &check_round(parsed, &1))
      finish_check(parsed, results, rounds)
    end
  end

  defp finish_check(parsed, results, rounds) do
    differing = Enum.count(results, &(&1 != :ok))

    Log.step(
      "#{rounds - differing}/#{rounds} round(s) match this engine's own pairing" <>
        if(differing == 0, do: "", else: " - #{differing} differ")
    )

    standings = check_standings(parsed)

    if differing == 0 and standings != :differs, do: 0, else: 1
  end

  # A team Swiss: every team round re-paired by `Ainalrami.TeamPairing`
  # (C.04.6) from the history before it - `Ainalrami.TeamReplay` has the
  # reading of the file. Reported in the individual replay's shape, pairs
  # as `{white team, black team}` (White on board 1) and the bye as
  # `{team, nil}`. Unlike the individual replay a colour difference is a
  # difference: Article 4 decides every team colour from the initial
  # colour, which the file gives (152) or round 1 shows.
  defp check_team(parsed, settings, flags) do
    history = TeamReplay.history(parsed)
    rounds = TeamReplay.paired_rounds(history)

    if rounds == 0 do
      Log.warn("no completed rounds to check")
      0
    else
      Log.step("Checking #{rounds} team round(s) - #{TeamReplay.describe(settings)}")

      opts = [expected_rounds: parsed.tournament[:number_of_rounds]]
      {colour, source} = TeamReplay.initial_colour(history, parsed.tournament, settings, opts)

      Log.detail(
        "initial colour #{colour}" <>
          if(source == :file,
            do: " (152)",
            else: " (no 152 in the file: the colour that reproduces round 1 best)"
          )
      )

      opts =
        Keyword.put(opts, :initial_colour, colour) ++
          team_engine_flags(flags) ++ TeamCLI.keep_apart_opts(parsed.tournament)

      if opts[:forbidden_pairs] || opts[:soft_pairs] do
        Log.warn(
          "the file keeps teams apart (XXO team-forbidden / team-soft-pairs), the " <>
            "organiser's rule and not C.04.6 - every round is replayed WITH it, so this is " <>
            "not a pure FIDE check, and a FIDE checker will not reproduce a round it changed"
        )
      end

      case TeamCLI.unknown_team(parsed, parsed.tournament) do
        nil ->
          results = Enum.map(1..rounds, &check_team_round(history, &1, settings, opts))
          finish_check(parsed, results, rounds)

        message ->
          Log.error(message)
          1
      end
    end
  end

  # A team round robin: every round against the Berger table
  # (`TeamReplay.check_round_robin/3`), the colours included - the table
  # gives them. A scheduled match the file has nothing for is reported but
  # is not a difference: it was not recorded, not paired otherwise.
  defp check_team_round_robin(parsed, settings) do
    history = TeamReplay.history(parsed)
    rounds = TeamReplay.paired_rounds(history)

    if rounds == 0 do
      Log.warn("no completed rounds to check")
      0
    else
      Log.step(
        "Checking #{rounds} team round(s) - #{TeamReplay.describe(settings)}, " <>
          "#{map_size(history)} teams"
      )

      results = Enum.map(1..rounds, &check_round_robin_round(history, &1, settings))
      finish_check(parsed, results, rounds)
    end
  end

  defp check_round_robin_round(history, round, settings) do
    check = TeamReplay.check_round_robin(history, round, settings)

    unless check.missing == [] do
      Log.warn(
        "round #{round}: no record of the scheduled match(es) #{inspect(check.missing)} " <>
          "(no games, no 330)"
      )
    end

    case check.result do
      :ok ->
        Log.detail("round #{round}: matches the Berger table")
        :ok

      :colours ->
        Log.warn(
          "round #{round}: DIFFERS in colours only - board-1 colours reversed against the " <>
            "Berger table in #{length(check.differing)} match(es): #{inspect(check.differing)}"
        )

        Log.warn("  file:   #{inspect(check.file)}")
        Log.warn("  table:  #{inspect(check.engine)}")
        :differs

      :differs ->
        Log.warn("round #{round}: DIFFERS from the Berger table")
        Log.warn("  file:   #{inspect(check.file)}")
        Log.warn("  table:  #{inspect(check.engine)}")
        :differs

      :beyond ->
        Log.warn("round #{round}: the Berger table has no such round (#{inspect(check.file)})")
        :differs
    end
  end

  defp check_team_round(history, round, settings, opts) do
    case TeamReplay.check_round(history, round, settings, opts) do
      {:ok, _file} ->
        Log.detail("round #{round}: matches")
        :ok

      {:colours, file, engine, differing} ->
        Log.warn(
          "round #{round}: DIFFERS in colours only - same pairing, board-1 colours differ " <>
            "in #{length(differing)} match(es): #{inspect(differing)}"
        )

        Log.warn("  file:   #{inspect(file)}")
        Log.warn("  engine: #{inspect(engine)}")
        :differs

      {:differs, file, engine} ->
        Log.warn("round #{round}: DIFFERS")
        Log.warn("  file:   #{inspect(file)}")
        Log.warn("  engine: #{inspect(engine)}")
        :differs

      {:no_pairing, reason} when reason in [:no_legal_pairing, :no_legal_bye] ->
        Log.warn("round #{round}: this engine finds no legal pairing at all (#{inspect(reason)})")

        :differs

      {:no_pairing, reason} ->
        Log.warn("round #{round}: this engine could not pair it (#{inspect(reason)})")
        :differs
    end
  end

  # What the individual replay should say about the file's `192` before it
  # starts: a code FIDE's table does not have, the draft table's spelling,
  # the 2017 edition (this engine pairs the current one), the virtual
  # points a Baku file is replayed with.
  defp report_type_code(parsed) do
    code = parsed.tournament[:type_code]

    case is_binary(code) and code != "" and TypeCode.parse(code) do
      false ->
        :ok

      :error ->
        Log.warn(
          "192 #{String.trim(code)} is not a code in FIDE's Tournament Type Code Table - " <>
            "replayed as a Dutch Swiss"
        )

      {:ok, description} ->
        if description[:legacy?] do
          Log.detail(
            "192 #{description.code} is the draft TRF-2026 table's spelling of FIDE_DUTCH_2025"
          )
        end

        if TypeCode.edition(description, parsed.tournament[:start_date]) == 2017 do
          Log.warn(
            "192 #{description.code}: the Dutch system's 2017 edition, in force before " <>
              "1 July 2025 - this engine pairs the current C.04.3 (effective 1 February " <>
              "2026), so a round may differ where the editions do"
          )
        end

        if description.baku? do
          Log.detail("Baku acceleration: the virtual points the file gives (XXA/250)")
        end
    end

    :ok
  end

  defp check_unreplayable(parsed, reason) do
    Log.warn(
      "rounds: not replayed - #{reason}. This checker replays the Dutch system (C.04.3), " <>
        "C.04.6 team Swiss events and team round robins, so no round was compared " <>
        "(exit code #{@not_replayed})"
    )

    if check_standings(parsed) == :differs, do: 1, else: @not_replayed
  end

  # The second half of the checker's job (FIDE's VCL4THP Q21): do the final
  # ranks in the file follow its own tie-break list? The standings are
  # recomputed from the games with `Ainalrami.Tiebreaks` under the file's
  # `212` (or the score followed by its `202`), and every player whose
  # column 86-89 rank disagrees is reported. Players still level after the
  # whole list may stand in any order among themselves - that order is
  # drawing of lots (C.07 4.2), not something a program can check.
  #
  # Skipped, with a note, when the file carries no tie-break list or no
  # final ranks - there is nothing to check against.
  defp check_standings(parsed) do
    list =
      case parsed.tournament do
        %{standings_order: [_ | _] = order} -> order
        %{tie_breaks: [_ | _] = codes} -> ["PTS" | codes]
        _ -> nil
      end

    ranks = Map.new(parsed.players, &{&1.rank, &1[:final_rank]})

    cond do
      is_nil(list) ->
        Log.detail("standings: no tie-break list in the file (202/212) - not checked")
        :skipped

      # A team file's ranks are the teams', in TRF26 `310` records (an
      # `013`-only file has none), ranked with the team tie-breaks.
      Map.get(parsed, :teams, []) != [] ->
        check_team_standings(parsed, list)

      Enum.all?(ranks, fn {_id, r} -> r in [nil, 0] end) ->
        Log.detail("standings: no final ranks in the file (columns 86-89) - not checked")
        :skipped

      true ->
        event = standings_event(parsed)

        case Ainalrami.Tiebreaks.rank(event, list, with_dropped: true) do
          {:ok, standings, dropped} ->
            unless dropped == [] do
              Log.detail(
                "standings: #{Enum.join(dropped, ", ")} dropped - unrated players and " <>
                  "no rating given for them (C.07 Article 10)"
              )
            end

            compare_standings(standings, ranks, list, "player")

          {:error, reason} ->
            Log.warn("standings: cannot be checked - #{reason}")
            :differs
        end
    end
  end

  # A team event: the teams' `310` ranks against
  # `Ainalrami.Tiebreaks.Team.rank/3` on `Team.from_trf/2`'s event (match
  # points from the file's `362`, teams by their `310` numbers).
  defp check_team_standings(parsed, list) do
    ranks =
      parsed.teams
      |> Enum.with_index(1)
      |> Map.new(fn {team, index} -> {Map.get(team, :number) || index, team[:final_rank]} end)

    if Enum.all?(ranks, fn {_id, r} -> r in [nil, 0] end) do
      Log.detail(
        "standings: a team event with no team ranks in the file (TRF26 310, columns 69-71)" <>
          " - not checked"
      )

      :skipped
    else
      event = Ainalrami.Tiebreaks.Team.from_trf(parsed)

      case Ainalrami.Tiebreaks.Team.rank(event, list, with_dropped: true) do
        {:ok, standings, dropped} ->
          unless dropped == [] do
            Log.detail(
              "standings: #{Enum.join(dropped, ", ")} dropped - no value for these teams"
            )
          end

          compare_standings(standings, ranks, list, "team")

        {:error, reason} ->
          Log.warn("standings: cannot be checked - #{reason}")
          :differs
      end
    end
  end

  defp compare_standings(standings, ranks, list, who) do
    # A shared rank r held by k players stands for the places r..r+k-1.
    places =
      standings
      |> Enum.group_by(& &1.rank)
      |> Enum.flat_map(fn {rank, rows} ->
        Enum.map(rows, &{&1.id, {rank, rank + length(rows) - 1, &1.values}})
      end)
      |> Map.new()

    # `{file_rank} <- [...]`, not `file_rank = ...`: as a filter the latter
    # drops a nil, and a player with no rank in the file is one to report.
    wrong =
      for {id, {low, high, values}} <- Enum.sort(places),
          {file_rank} <- [{ranks[id]}],
          not (is_integer(file_rank) and file_rank >= low and file_rank <= high),
          do: {id, file_rank, low, high, values}

    if wrong == [] do
      Log.step("standings: all #{map_size(places)} ranks follow #{Enum.join(list, " ")}")
      :ok
    else
      Log.warn("standings: #{length(wrong)} rank(s) do not follow #{Enum.join(list, " ")}")

      for {id, file_rank, low, high, values} <- wrong do
        expected = if low == high, do: "#{low}", else: "#{low}-#{high}"
        detail = Enum.map_join(list, " ", &"#{&1}=#{format_value(values[&1])}")

        Log.warn(
          "  #{who} #{id}: file says #{inspect(file_rank)}, tie-breaks give #{expected} (#{detail})"
        )
      end

      :differs
    end
  end

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, [:compact, decimals: 4])
  defp format_value(v), do: inspect(v)

  defp check_round(parsed, round) do
    before = state_before_round(parsed.players, round, parsed.tournament[:point_system])

    # The file's own organiser records (`XXO`), as they stood for this
    # round - `[]` for a file without any.
    opts =
      pairing_opts(parsed.tournament) ++ PairingInput.organiser_opts(parsed.tournament, round)

    expected = EventFormat.pair_next_round(before, opts)
    actual = recorded_pairs(parsed.players, round)

    # A match's second leg is not chosen: the round before, every colour
    # reversed. So its colours are part of what is checked, where a
    # Dutch-system round leaves the first colour to the drawing of lots.
    second_leg? = opts[:match_format] == true and EventFormat.kind(before, opts) == :second_leg

    cond do
      second_leg? and Enum.sort(expected) == Enum.sort(actual) ->
        Log.detail("round #{round}: matches - the second leg of round #{round - 1}'s match")
        :ok

      second_leg? ->
        Log.warn(
          "round #{round}: DIFFERS from round #{round - 1} with the colours reversed (XXM)"
        )

        Log.warn("  file:   #{inspect(Enum.sort(actual))}")
        Log.warn("  engine: #{inspect(Enum.sort(expected))}")
        :differs

      true ->
        compare_round(expected, actual, round)
    end
  rescue
    e in Pairing.NoValidPairingError ->
      Log.warn(
        "round #{round}: this engine finds no legal pairing at all - #{Exception.message(e)}"
      )

      :differs

    e in EventFormat.Error ->
      Log.warn("round #{round}: #{Exception.message(e)}")
      :differs

    e in ByePreference.RefusedError ->
      Log.warn("round #{round}: #{Exception.message(e)}")
      :differs
  end

  defp compare_round(expected, actual, round) do
    if composition(expected) == composition(actual) do
      Log.detail("round #{round}: matches" <> colour_note(expected, actual))
      :ok
    else
      Log.warn("round #{round}: DIFFERS")
      Log.warn("  file:   #{inspect(Enum.sort(actual))}")
      Log.warn("  engine: #{inspect(Enum.sort(expected))}")
      :differs
    end
  end

  # How many rounds were actually PAIRED. Taken over players rather than the
  # header's own round count, which states the tournament's intended length,
  # not its progress.
  #
  # `length(&1.games)` is not that number. An arbiter's bye is recorded
  # BEFORE its round is paired - that is how the engine knows to leave the
  # player out - so a file waiting to have round N paired already carries a
  # round-N `H` or `Z` for everyone who asked to sit it out, and
  # `parse_games/1` sizes the list from the line. One such player made this
  # count one high, and the checker then diffed a round the file had never
  # paired: `recorded_pairs/2` discards every non-participating game, so
  # `actual` was `[]`, while `state_before_round/3` reconstructs exactly the
  # position that round is to be paired FROM and duly pairs it. Every file
  # with a pre-recorded bye for its pending round reported a spurious
  # mismatch on its last round and exited 1.
  #
  # A round counts as paired if ANY player took part in its pairing. Rounds
  # before that are counted too even if nobody's entry participated, which
  # is bbpPairings' rule as well: `trf.cpp:329-340` raises `playedRounds` to
  # `matches.size()` for any non-empty entry and to `matches.size() + 1`
  # only when `participatedInPairing`.
  #
  # bbpPairings on the same file reaches the same place by a different
  # route. Its reader pads every short history out to the pending round
  # with non-participating self-matches (`evenUpMatchHistories`), so its
  # checker does visit round N - and then finds every player sitting it out,
  # computes an empty matching, and prints nothing. Not checking the round
  # at all says the same thing more plainly.
  defp completed_rounds(players) do
    players |> Enum.map(&paired_through/1) |> Enum.max(fn -> 0 end)
  end

  defp paired_through(player) do
    player.games
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {game, round}, paired ->
      cond do
        blank?(game) -> paired
        Trf.participated_in_pairing?(game) -> round
        true -> max(paired, round - 1)
      end
    end)
  end

  # An entry holding nothing at all - no opponent, no colour, no result.
  # `parse_games/1` keeps these for interior rounds a late entrant missed,
  # and they are evidence of nothing.
  defp blank?(game) do
    is_nil(game.opponent_rank) and is_nil(game.colour) and
      (is_nil(game.result) or String.trim(game.result) == "")
  end

  # The tournament as it stood immediately before `round` was paired:
  # every earlier game, plus this round's own result for anyone who did
  # NOT participate in the pairing. That last part is not an optimisation
  # - an arbiter-assigned bye is recorded in advance precisely so the
  # engine leaves that player out, so replaying without it would ask the
  # engine to pair somebody who had already been excused.
  defp state_before_round(players, round, point_system) do
    points = point_system || Trf.default_point_system()

    Enum.map(players, fn player ->
      earlier = Enum.take(player.games, round - 1)

      games =
        case Enum.at(player.games, round - 1) do
          nil -> earlier
          game -> if Trf.participated_in_pairing?(game), do: earlier, else: earlier ++ [game]
        end

      %{
        player
        | games: games,
          points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, points)))
      }
    end)
  end

  # The pairing the file records for `round`, as {white, black} with `nil`
  # for a pairing-allocated bye. Each game is claimed by its White so the
  # pair is emitted once; players who sat the round out contribute nothing.
  defp recorded_pairs(players, round) do
    Enum.flat_map(players, fn player ->
      case Enum.at(player.games, round - 1) do
        nil ->
          []

        game ->
          cond do
            not Trf.participated_in_pairing?(game) -> []
            is_nil(game.opponent_rank) -> [{player.rank, nil}]
            game.colour == "w" -> [{player.rank, game.opponent_rank}]
            game.colour == "b" -> []
            # No colour recorded: claim it from the lower rank so the pair
            # is still emitted exactly once.
            player.rank < game.opponent_rank -> [{player.rank, game.opponent_rank}]
            true -> []
          end
      end
    end)
  end

  defp composition(pairs) do
    pairs
    |> Enum.map(fn {a, b} -> Enum.sort_by([a, b], &(&1 || :infinity)) end)
    |> Enum.sort()
  end

  defp colour_note(expected, actual) do
    if Enum.sort(expected) == Enum.sort(actual),
      do: "",
      else: " (same pairing, different colours)"
  end

  defp write_pairs(pairs, positional_rest) do
    for {white, black} <- pairs do
      Log.detail(board_description(white, black))
    end

    output_text = format_pairs(pairs)

    case positional_rest do
      [output_path | _] -> write_file!(output_path, output_text)
      [] -> IO.write(output_text)
    end
  end

  # Written to a sibling temp file and renamed into place, so an interrupted
  # or failing write leaves the previous file untouched rather than a
  # half-written one. Same directory on purpose: `File.rename/2` is only
  # atomic within a filesystem, and `System.tmp_dir!/0` is routinely on
  # another one.
  defp write_file!(output_path, text) do
    temp_path = "#{output_path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temp_path, text)

      case File.rename(temp_path, output_path) do
        :ok ->
          :ok

        {:error, reason} ->
          raise File.Error, reason: reason, action: "write to file", path: output_path
      end
    rescue
      e ->
        File.rm(temp_path)
        reraise e, __STACKTRACE__
    end

    Log.detail("wrote #{output_path}")
  end

  defp board_description(white, nil), do: "##{white} - pairing-allocated bye"
  defp board_description(white, black), do: "##{white} (white) vs. ##{black} (black)"

  # Same shape as javafo.jar's own output file: a count line, then one
  # "white black" line per pair (0 for a bye), CRLF throughout - confirmed
  # against a real javafo.jar run, not assumed.
  defp format_pairs(pairs) do
    header = "#{length(pairs)}\r\n"
    body = Enum.map_join(pairs, "", fn {w, b} -> "#{w} #{b || 0}\r\n" end)
    header <> body
  end

  defp read_input(input_path) do
    case File.read(input_path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Log.error("could not read #{input_path}: #{:file.format_error(reason)}")
        {:error, :halt}
    end
  end

  defp parse_input(text, flags) do
    {:ok, text |> Trf.parse() |> with_input_flags(flags)}
  rescue
    e in Trf.ValidationError ->
      Log.error("invalid TRF file: #{Exception.message(e)}")
      {:error, :halt}
  end

  defp report_roster(parsed) do
    round_count = parsed.players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)

    Log.detail("#{length(parsed.players)} players, #{length(parsed.teams)} teams")
    Log.detail("#{round_count} round(s) of history in the file")

    for p <- parsed.players do
      Log.detail("##{p.rank} #{p.name} (#{format_rating(p.fide_rating)}) - #{p.points} pts")
    end

    round_count
  end

  defp format_rating(0), do: "unrated"
  defp format_rating(rating), do: "#{rating}"

  defp usage_error(message) do
    Log.error(message)
    print_help()
    1
  end

  defp print_help_and_ok do
    print_help()
    0
  end

  defp print_version_and_ok do
    print_version()
    0
  end

  defp print_help do
    IO.puts("""
    ainalrami - a FIDE Dutch-system Swiss pairing engine (and C.04.6 team Swiss)

    Usage:
      ainalrami <input.trf> -p [<output.trf>]   Pair the next round (writes to
                                                stdout if <output.trf> is omitted);
                                                on a team file team against team
                                                (see "Team events" below)
      ainalrami -g [<output.trf>]                Random Tournament Generator
      ainalrami <input.trf> -c                   Pairings and Tie-Break Checker:
                                                 replay a tournament, diff every
                                                 round against this engine, and
                                                 check the final ranks against
                                                 the file's own tie-break list
                                                 (202/212); for a team file,
                                                 the team rounds (C.04.6, or
                                                 the Berger tables for a team
                                                 round robin) and the teams'
                                                 ranks (TRF26 310).
                                                 Exit 0 all match, 1 something
                                                 differs, 2 a system that
                                                 cannot be replayed (individual
                                                 round robin, Scheveningen, ...)
      ainalrami <input.trf> -x                   Explain: pair the next round and
                                                 report, per bracket, which
                                                 criteria decided it
      ainalrami <input.trf> -s [<output>]        Standings: rank by the file's
                                                 tie-break list (202/212) or
                                                 --tie-breaks=; RANK ID values

    Options:
      -q, --quiet    Warnings and errors only
      -d, --debug    Add engine internals (bracket paths, sizes, timings)
      --force=A-B  With -x: the best round in which A and B meet, and
                   what it costs against the round that was paired
      --absent=N   With -x: N did not turn up - the least disruptive
                   legal fixes, each with who else moves and what it costs
      --judge=1-5,2-6,3-0   With -x: a whole other round (0 = the bye),
                   judged against the one that was paired
      --bye-alternatives    With -x: had each other player of the bye's
                   bracket taken the bye instead
      --float-alternatives  With -x: had each other player floated instead
      --alternative-pairs   With either: under each alternative, its boards
                   that differ from the played round, and the played ones
      --max-candidates=N|all   With either: how many candidates a question
                   searches before it says "not worked out" (default 12)

    The tournament, over what the file says (-p, -x, -c):
      --rounds=N                the round count (142/XXR)
      --system=dutch|dubov|burstein   the Swiss system (192 FIDE_DUBOV[_BAKU]
                                picks Dubov, C.04.4.1; FIDE_BURSTEIN[_BAKU]
                                Burstein, C.04.4.2); -p and -c only for
                                those two, and a flag that contradicts 192
                                is refused (exit 2). Also -g
      --provisional-rating=12:1500/17:1400   Dubov: the Chief Arbiter's
                                rating for an unrated player (1.1.2), over
                                XXO provisional-rating RANK RATING
      --initial-colour=white|black   the drawing of lots (152/XXC)
      --points=3,1,0            the point system (BB*/162); or by name:
                                win:3,draw:1,loss:0,bye:1,forfeit-loss:0,
                                zero-bye:0,half-bye:1,full-bye:3,forfeit-win:3,
                                unknown:1 (a ? result, 162's X)
                                (also -s)
      --forbidden=1,4/2,9,12@3-5   forbidden groups, added to XXP/260;
                                @ROUND or @FIRST-LAST limits one to rounds
      --acceleration=baku       C.04.7's virtual points, worked out here for
                                a file with no XXA/250; needs the round count
      --baku-group-a=N          Group A's last starting rank, when the field
                                grew after round 1 (default: 2 x ceil(n/4))
      --virtual-points=1-10:1,1,0.5/11:0.5
                                any other table, RANKS:one value per round
                                (an organiser's acceleration, announced)
      --half-bye=3,7 --zero-bye=12 --full-bye=20   (-p, -x) byes asked for
                                in the round being paired; zero = absent
      --cascade-order           (-p) boards in the order the brackets were
                                paired, not C.04.2 3.6's
      --proof=FILE[.gz]         (-p) also write a proof per round: every
                                matching the engine solved is optimal,
                                every completability answer holds, and
                                every published pair came off one of
                                them; JSON Lines, check it with
                                tools/verify-proof/verify.exs

    Bye preferences (-p and -x; an organiser's rule, NOT FIDE - a round they
    change is not a pure FIDE pairing, and a warning says so on stderr):
      --bye-want=RANKS       must get the pairing-allocated bye, if any legal
                             round gives it to them
      --bye-want-soft=RANKS  rather gets it: decides among the players on the
                             bye score, never lifts the bye to a higher score
      --bye-avoid=RANKS      must not get it (a bye exclusion)
      --bye-avoid-soft=RANKS rather not: someone else on the bye score takes
                             it if anyone can
      --bye-exclude=RANKS    the plain bye exclusion (the library's
                             :bye_exclusions): as --bye-avoid, reported as
                             the organiser's exclusion
      RANKS is starting ranks separated by commas, each optionally with the
      rounds it applies to: --bye-want=5,12@3-4+7 (12 in rounds 3, 4 and 7)
      In the file: XXO bye-want 5 12@3-4+7 (and bye-want-soft, bye-avoid,
      bye-avoid-soft, bye-exclude)
      (-c replays with them, and says it is not a pure FIDE check)

    Soft pairs (-p and -x; an organiser's wish, NOT FIDE, announced on stderr):
      --soft-pairs=1,4/2,9,12   groups of players to keep apart where the
                                criteria allow it (club protection, family);
                                2,9,12@3-5 for rounds 3 to 5 only
      --soft-position=strong|weak
                                strong (default): above C6, a float rather
                                than the pair; weak: after C21, ties only
      In the file: XXO soft-pairs 2 9 12 @3-5 / XXO soft-position weak

    Event formats (-p, -x, -c; also what the file's XXM and XXG lines say):
      --match-format            every match two games in a row, colours
                                reversed in the second: a Swiss pairs the odd
                                rounds and copies each even one reversed; a
                                round robin plays round k of one table as
                                rounds 2k-1 and 2k (CUSTOM_SWISS/_ROUNDROBIN)
      --groups=1-8/9-12,15      pairing groups (categories), each paired on
                                its own; ranks in no group form a last one;
                                a round robin plays one table per group
      -g takes --match-format (Swiss, --roundrobin, --team=roundrobin) and
      --groups=N (N random groups) or --groups=RANKS/RANKS (Swiss, round robin)

      -h, --help     Show this help
          --version  Show the version number

    Generator options (-g), all --name=value; unset ones are chosen at random:
      --seed --players --rounds          the tournament (seed makes it repeatable;
                                         without one a fresh seed is drawn, and
                                         it is printed and written into the file)
      --ratings=2400,2350,...            each TPN's rating, in order
      --rating-range=1400-2700           ratings drawn from a range
      --rating-top=2600 --rating-step=20 [--rating-sigma=50]
                                         TPN 1 rated top, each next step lower
      --results=fide [--draw-rate=0.3]   results by the FIDE rating table
      --full-bye-pct --half-bye-pct --zero-bye-pct
                                         byes of each kind, % per player-round
      --forfeit-win-pct --double-forfeit-pct
                                         forfeits, % of games
      --odd-results-pct                  1/2-0, 0-1/2 and 0-0, % of games
      --tie-breaks=BH/C1,BH,SB           write the list (202) and the final
                                         ranks it gives
      --forfeit-pct --bye-pct --forbidden-pct --acceleration=baku|random
      --initial-colour=white|black
      --unset-chance=50                  % chance each unset bye, forfeit,
                                         odd-result, Baku and tie-break option
                                         is switched on (at a random level);
                                         unset results follow the rating table
      --unset=fixed                      leave unset options off and results
                                         uniform instead (the corpus default)
      --dialect=engine|trf26             how the file is spelled: XXR/XXA/XXP
                                         (default) or TRF26's 142/250/260/240;
                                         same seed, same tournament. Team and
                                         round-robin files are always TRF26

    Round robins: -p on a file whose 192 is BERGER_ROUNDROBIN_Gn (or
    FIDE_ROUNDROBIN, BERGER_/FIDE_DOUBLEROUNDROBIN, or a 092 round robin)
    gives the next round of the Berger table (players numbered by starting
    rank; the free player as PLAYER 0); -c compares every round with it.
      -g --roundrobin [--players --rounds --cycles --forfeit-pct --draw-rate
                       --rating-range --tie-breaks --seed --match-format
                       --groups]

    Team events:
      -p on a team file (TRF26 310 rosters + 001 games; 192 FIDE_TEAM_... for a
      C.04.6 Swiss, BERGER_TEAM_ROUNDROBIN_Gn for a round robin) writes
        COUNT                one line per match, the bye counted
        WHITE BLACK          team numbers (310), White = White on board 1;
                             the bye (or a round robin's free team) as TEAM 0
      --lineups            then the boards: COUNT, and MATCH BOARD WHITE BLACK
                           (players' starting ranks, 0 = nobody); seats a 300
                           record's order, else the free players in 310 order
      --boards=N           boards per match, when no match in the file says
      A team sits the round out when every player has the round recorded
      (a Z/H/F bye or 240 record). -x explains the round (bye, brackets,
      upfloater sets, colour rules).
      --absent-teams=2,5   (-p, -x) these teams sit the round out
      --team-type=a|b|none --score=mp|gp --secondary=yes|no
                           (-p, -x, -c, a team Swiss) in place of the 192 code's
      --rounds=N --initial-colour=white|black   as for an individual file
      --max-upfloater-sets=N   C.04.6 3.5's search budget (default 200000)
      --explain-limit=N    (-x) entries kept per list of the account (10)
      Keeping teams apart (a team Swiss; the organiser's rule, NOT C.04.6,
      announced on stderr), by TEAM number:
      --team-forbidden=3,11,16/1,8@1-2   (-p, -x, -c) groups that must not
                           meet; @ROUND or @FIRST-LAST limits one to rounds.
                           A round they leave unpairable is refused, naming
                           the groups that, lifted, would let it pair
      --team-soft-pairs=3,11,16          (-p, -x) rather not meet: avoided
                           only between pairings C.04.6 ranks equal (after
                           C10, inside a bracket), never a reason to fail
      In the file: XXO team-forbidden 3 11 16 / XXO team-soft-pairs 1 8 @1-2
      (-c replays with them; XXP/260 name players and are refused here)

    Standings (-s; -c checks the file's ranks the same way):
      --tie-breaks=BH,SB        the list, in place of the file's 202/212; one
                                starting with PTS/MPTS/GPTS is the whole order
      --cap-rounds=played|announced   C.07 16.4.2's round count for a dummy
      XXO round-ratings RANK R1 R2 ...   in the file: the rating held in
                                each round (- for none), for the rating
                                tie-breaks

    Team generator (-g --team=swiss|roundrobin), unset ones drawn from the seed:
      --seed --teams --rounds --boards --reserves --cycles
      --team-type=a|b|none --score=mp|gp --secondary=yes|no   (the 192 code)
      --initial-colour=white|black
      --match-points=2,1,0 --pab=draw|win --forfeit-match-points=N
      --forfeit-pct --match-forfeit-pct --absent-team-pct
      --absent-player-pct --out-of-order-pct --draw-rate
      --tie-breaks=MPTS,GPTS,EDE         212 and the teams' final ranks
    """)
  end

  defp print_version do
    case Application.spec(:ainalrami, :vsn) do
      nil -> IO.puts("unknown")
      vsn -> IO.puts(List.to_string(vsn))
    end
  end
end
