# One Burstein or Lim round timed under one walk (`Ainalrami.MatchingWalk`),
# on the history `docs/perf-burstein-lim-2026-11.md` profiled: a nine-round
# `Ainalrami.Generator` event paired by the Dutch engine, cut to its first
# `games` rounds; `draws` rewrites every played game as a draw, so an even
# field is one scoregroup.
#
#   MIX_ENV=prod mix run tools/burstein_lim_timing.exs burstein 1000 normal 4 new
#
# Prints the wall time and a SHA-256 of the whole answer, so the `old` and
# `new` lines of one case can be compared.

alias Ainalrami.{Burstein, DubovCLI, Generator, Lim, MatchingWalk, Trf}

[system, n, kind, k, mode] = System.argv()
n = String.to_integer(n)
k = String.to_integer(k)
mode = String.to_existing_atom(mode)
true = mode in [:old, :new]

{text, _} = Generator.generate(seed: 4242 + n, players: n, rounds: 9, system: :dutch)
t = Trf.parse(text)
ps = Trf.default_point_system()

players =
  Enum.map(t.players, fn p ->
    games =
      p.games
      |> Enum.take(k)
      |> Enum.map(fn g ->
        if kind == "draws" and Trf.game_was_played?(g.result) and is_integer(g.opponent_rank),
          do: %{g | result: "="},
          else: g
      end)

    %{p | games: games, points: Enum.sum(Enum.map(games, &Trf.points_for_game(&1, ps))) / 1}
  end)

groups = players |> Enum.frequencies_by(& &1.points)
opts = DubovCLI.burstein_opts(t.tournament)
mod = if system == "burstein", do: Burstein, else: Lim

t0 = System.monotonic_time(:millisecond)
answer = MatchingWalk.with_mode(mode, fn -> mod.pair_round(players, opts) end)
ms = System.monotonic_time(:millisecond) - t0

sha =
  :crypto.hash(:sha256, :erlang.term_to_binary(answer, [:deterministic]))
  |> Base.encode16(case: :lower)
  |> binary_part(0, 16)

IO.puts(
  "TIMING #{system} n=#{n} #{kind} round=#{k + 1} groups=#{map_size(groups)} " <>
    "largest=#{Enum.max(Map.values(groups))} mode=#{mode} ms=#{ms} " <>
    "ok=#{match?({:ok, _}, answer)} sha=#{sha}"
)
