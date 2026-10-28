# What a pairing proof costs, on single positions.
#
#   mix run tools/proof_bench.exs DIR [proof]
#
# Generates (once, into DIR) tournaments of 30, 100, 200, 400, 600 and
# 1,000 players with five rounds played (`ainalrami -g`, seed 20261028 +
# players), and times pairing round 6 in this VM: median of 5 with the
# proof off (3 from 400 players up). With `proof`, also the reference path
# alone (the engine's shortcuts switched off, nothing recorded) once, and
# the proof once: wall time, solves, bytes, and gzipped bytes; the proof is
# left in DIR/<players>.jsonl for `tools/verify-proof/verify.exs` to time.
#
# Without `proof` the script touches nothing but `Ainalrami.CLI.run/1`,
# so it runs unchanged in a checkout of a release without the option: the
# off column of two builds is the comparison that shows the option costs
# nothing when it is off.

[dir | rest] = System.argv()
proof? = rest == ["proof"]
File.mkdir_p!(dir)
Ainalrami.Log.set_level(:quiet)

median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
ms = fn us -> :erlang.float_to_binary(us / 1000, decimals: 1) end

for players <- [30, 100, 200, 400, 600, 1000] do
  trf = Path.join(dir, "#{players}.trf")

  unless File.exists?(trf) do
    0 =
      Ainalrami.CLI.run(
        ~w(-g #{trf} --seed=#{20_261_028 + players} --players=#{players} --rounds=5 -q)
      )
  end

  out = Path.join(dir, "#{players}.out")
  pair = fn extra -> Ainalrami.CLI.run([trf, "-p", out, "--rounds=9", "-q" | extra]) end

  runs = if players >= 400, do: 3, else: 5
  pair.([])
  off = median.(for _ <- 1..runs, do: elem(:timer.tc(fn -> pair.([]) end), 0))
  line = "#{players} players: off #{ms.(off)} ms"

  line =
    if proof? do
      flags = ~w(AINALRAMI_CERT AINALRAMI_DIRECT AINALRAMI_NOFAST)
      Enum.zip(flags, ~w(off off 1)) |> Enum.each(fn {k, v} -> System.put_env(k, v) end)
      {reference, _} = :timer.tc(fn -> pair.([]) end)
      Enum.each(flags, &System.delete_env/1)

      file = Path.join(dir, "#{players}.jsonl")
      {on, _} = :timer.tc(fn -> pair.(["--proof=" <> file]) end)
      text = File.read!(file)
      solves = length(String.split(text, ~s("id":))) - 1

      line <>
        ", reference path #{ms.(reference)} ms, proof on #{ms.(on)} ms, " <>
        "#{solves} solves, #{byte_size(text)} bytes (#{byte_size(:zlib.gzip(text))} gzipped)"
    else
      line
    end

  IO.puts(line)
end
