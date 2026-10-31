# How much the open readings of C.04.4.2 (Burstein) matter: every round after
# the seeding rounds of generated events, paired by the brute-force reference
# under the chosen reading and under each alternative, and the rounds where
# the pairing (or a colour) differs counted.
#
#     MIX_ENV=test mix run tools/burstein_readings.exs --first 1 --last 20000
#
# Options: --workers (default: all schedulers), --sizes 4..10. The events are
# `Ainalrami.Test.BursteinEvents`'s, paired forward by the engine; the
# alternatives are the reference's switches (`:b3`, `:b4`, `:b6`; see
# `test/support/burstein_reference.ex`). One line of output per alternative.

alias Ainalrami.Burstein
alias Ainalrami.Test.{BursteinEvents, BursteinReference}

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [first: :integer, last: :integer, workers: :integer, sizes: :string]
  )

first = Keyword.get(opts, :first, 1)
last = Keyword.get(opts, :last, 2000)
workers = Keyword.get(opts, :workers, System.schedulers_online())

sizes =
  case Keyword.get(opts, :sizes, "4..10") |> String.split("..") do
    [a, b] -> String.to_integer(a)..String.to_integer(b)
  end

alternatives = [
  {"B3 unplayed rounds add nothing to the index", [b3: :nothing]},
  {"B4 the zero-point-bye run must include the round being paired", [b4: :current_too]},
  {"B6 5.2's 'higher ranked' by score first", [b6: :score]}
]

counts =
  first..last
  |> Task.async_stream(
    fn seed ->
      local = :counters.new(length(alternatives) + 1, [])

      BursteinEvents.play(seed, sizes, fn players, o, round ->
        case Burstein.pair_round(players, o) do
          {:ok, e} ->
            if round > Burstein.seeding_rounds(o[:expected_rounds]) do
              :counters.add(local, 1, 1)
              base = BursteinReference.ref_round(players, o)

              alternatives
              |> Enum.with_index(2)
              |> Enum.each(fn {{_label, switch}, i} ->
                if BursteinReference.ref_round(players, o ++ switch) != base,
                  do: :counters.add(local, i, 1)
              end)
            end

            e.pairs ++ if(e.bye, do: [{e.bye, nil}], else: [])

          {:error, _} ->
            :stop
        end
      end)

      for i <- 1..(length(alternatives) + 1), do: :counters.get(local, i)
    end,
    max_concurrency: workers,
    timeout: :infinity
  )
  |> Enum.reduce(List.duplicate(0, length(alternatives) + 1), fn {:ok, l}, acc ->
    Enum.zip_with(l, acc, &+/2)
  end)

[rounds | differ] = counts
IO.puts("seeds #{first}..#{last}, sizes #{inspect(sizes)}: #{rounds} rounds after seeding")

for {{label, _}, n} <- Enum.zip(alternatives, differ) do
  IO.puts("  #{label}: #{n} rounds differ (#{Float.round(100 * n / max(rounds, 1), 2)}%)")
end
