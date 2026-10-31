# How much the open readings of C.04.4.3 (Lim) matter: every round of
# generated events, paired by the brute-force reference
# under the chosen reading and under each alternative, and the rounds where
# the pairing (or a colour) differs counted.
#
#     MIX_ENV=test mix run tools/lim_readings.exs --first 1 --last 20000
#
# Options: --workers (default: all schedulers), --sizes 4..10. The events are
# `Ainalrami.Test.LimEvents`'s, paired forward by the engine; the
# alternatives are the reference's switches (`:l4`, `:l6`, `:l12`; see
# `test/support/lim_reference.ex`). One line of output per alternative.

alias Ainalrami.Lim
alias Ainalrami.Test.{LimEvents, LimReference}

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
  {"L4 3.2.2's colour balance before 3.9's floater types", [l4: :colour_first]},
  {"L6 the scrutiny order before 5.2's colours", [l6: :order_first]},
  {"L12 the last round frees every pair from the colour limits", [l12: :every_pair]}
]

counts =
  first..last
  |> Task.async_stream(
    fn seed ->
      local = :counters.new(length(alternatives) + 1, [])

      LimEvents.play(seed, sizes, fn players, o, _round ->
        case Lim.pair_round(players, o) do
          {:ok, e} ->
            :counters.add(local, 1, 1)
            base = LimReference.ref_round(players, o)

            alternatives
            |> Enum.with_index(2)
            |> Enum.each(fn {{_label, switch}, i} ->
              if LimReference.ref_round(players, o ++ switch) != base,
                do: :counters.add(local, i, 1)
            end)

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
IO.puts("seeds #{first}..#{last}, sizes #{inspect(sizes)}: #{rounds} rounds")

for {{label, _}, n} <- Enum.zip(alternatives, differ) do
  IO.puts("  #{label}: #{n} rounds differ (#{Float.round(100 * n / max(rounds, 1), 2)}%)")
end
