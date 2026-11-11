# Finds, for every quality criterion of C.04.3 (2026) and for Article 4's
# order, a position and a deliberately wrong round whose first broken
# article is that one, and writes them to test/fixtures/articles/:
# NAME.trf (the position) and NAME.pairs (the wrong round, -p format).
#
#   MIX_ENV=test mix run tools/article_examples.exs [SEEDS]
#
# The wrong round is built from the reference: brackets above the chosen
# one as the reference pairs them, the chosen bracket replaced by a
# candidate that is worse first on the target criterion, and the brackets
# below paired by the reference given that bracket's downfloaters. The
# tests then check `rules` names exactly that criterion first.

alias AinalramiVerify.{Bracket, PairsFile, Position, RuleCheck, Trf, Walk}

seeds = String.to_integer(List.first(System.argv()) || "4000")
dir = "test/fixtures/articles"
File.mkdir_p!(dir)

targets = Bracket.criteria() ++ ["order"]

complete = fn pos, ctx, groups, k, prefix, {ps, df} ->
  {pairs, left} =
    Enum.reduce((k + 1)..(length(groups) - 1)//1, {prefix ++ ps, df}, fn j, {acc, mdps} ->
      b = Bracket.bracket(ctx, groups, j, mdps)
      %{candidate: {p2, d2}} = Bracket.best(ctx, b)
      {acc ++ p2, d2}
    end)

  bye = List.first(left)

  %{
    pairs:
      Enum.map(pairs, fn {a, b} ->
        {w, bl, _} = AinalramiVerify.Rules.colours(pos, a, b)
        {w, bl}
      end),
    bye: bye
  }
end

found =
  Enum.reduce_while(1..seeds, %{}, fn seed, found ->
    n = 6 + rem(seed, 5)
    rounds = 3 + rem(div(seed, 5), 4)

    trfs = Walk.positions(players: n, rounds: rounds, seed: seed, absences: if(rem(seed, 3) == 0, do: 0.12, else: 0.0))

    found =
      Enum.reduce(trfs, found, fn trf, found ->
        pos = trf |> Trf.parse() |> Position.build()
        ctx = Bracket.context(pos)

        try do
          if Bracket.completion(ctx, Bracket.mask(ctx, pos.pool)) == :none or length(pos.pool) < 4 do
            found
          else
            groups = Bracket.scoregroups(ctx)

            {found, _, _} =
              Enum.reduce(0..(length(groups) - 1)//1, {found, [], []}, fn k, {found, prefix, mdps} ->
                b = Bracket.bracket(ctx, groups, k, mdps)
                best = Bracket.best(ctx, b)
                scored = Bracket.scored(ctx, b)

                found =
                  Enum.reduce(scored, found, fn {cand, key, vec}, found ->
                    target =
                      cond do
                        key == best.key and cand != best.candidate and
                            Bracket.sequence_key(ctx, b, cand) > Bracket.sequence_key(ctx, b, best.candidate) ->
                          "order"

                        key > best.key ->
                          Enum.find(Bracket.criteria(), &(vec[&1] != best.vector[&1]))

                        true ->
                          nil
                      end

                    if target && not Map.has_key?(found, target) do
                      round = complete.(pos, ctx, groups, k, prefix, cand)
                      verdicts = RuleCheck.check(pos, round, colours: false)
                      first = List.first(verdicts)

                      if first && first.criterion == target && first.bracket == b.score do
                        IO.puts("#{target}: seed #{seed}, #{n} players, round #{pos.round}, bracket #{b.score}")
                        File.write!(Path.join(dir, "#{target}.trf"), trf)
                        File.write!(Path.join(dir, "#{target}.pairs"), PairsFile.write(round))
                        Map.put(found, target, true)
                      else
                        found
                      end
                    else
                      found
                    end
                  end)

                {found, prefix ++ elem(best.candidate, 0), elem(best.candidate, 1)}
              end)

            found
          end
        after
          Bracket.cleanup(ctx)
        end
      end)

    if Enum.all?(targets, &Map.has_key?(found, &1)), do: {:halt, found}, else: {:cont, found}
  end)

missing = Enum.reject(targets, &Map.has_key?(found, &1))
IO.puts("found #{map_size(found)}/#{length(targets)}; missing: #{Enum.join(missing, ", ")}")
