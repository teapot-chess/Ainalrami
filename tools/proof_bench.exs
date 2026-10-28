# What a pairing proof costs, on single positions.
#
#   mix run tools/proof_bench.exs DIR [proof]
#
# Generates (once, into DIR) tournaments of 30, 100, 200, 400, 600 and
# 1,000 players with five rounds played (`ainalrami -g`, seed 20261028 +
# players), and times pairing round 6 in this VM: median of 5 with the
# proof off (3 from 400 players up). With `proof`, also the reference path
# alone (the engine's shortcuts switched off, nothing recorded) once, and
# the proof once: wall time, weighted and cardinality records, bytes,
# gzipped bytes, and the VM's peak memory (sampled every 5 ms) for the off
# pairing and the proof; the proof is left in DIR/<players>.jsonl for
# `tools/verify-proof/verify.exs` to time.
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

# `fun.()`'s peak `:erlang.memory(:total)`, in MB, after a full collection.
peak = fn fun ->
  for pid <- Process.list(), do: :erlang.garbage_collect(pid)
  me = self()

  sampler =
    spawn(fn ->
      loop = fn loop, top ->
        receive do
          :stop -> send(me, {:peak, top})
        after
          5 -> loop.(loop, max(top, :erlang.memory(:total)))
        end
      end

      loop.(loop, :erlang.memory(:total))
    end)

  fun.()
  send(sampler, :stop)

  receive do
    {:peak, top} -> div(top, 1_048_576)
  end
end
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
  off_mb = peak.(fn -> pair.([]) end)
  line = "#{players} players: off #{ms.(off)} ms (#{off_mb} MB peak)"

  line =
    if proof? do
      flags = ~w(AINALRAMI_CERT AINALRAMI_DIRECT AINALRAMI_NOFAST)
      Enum.zip(flags, ~w(off off 1)) |> Enum.each(fn {k, v} -> System.put_env(k, v) end)
      {reference, _} = :timer.tc(fn -> pair.([]) end)
      Enum.each(flags, &System.delete_env/1)

      file = Path.join(dir, "#{players}.jsonl")
      {on, _} = :timer.tc(fn -> pair.(["--proof=" <> file]) end)
      on_mb = peak.(fn -> pair.(["--proof=" <> file]) end)
      text = File.read!(file)
      count = fn type -> length(String.split(text, ~s("type":"#{type}"))) - 1 end

      line <>
        ", reference path #{ms.(reference)} ms, proof on #{ms.(on)} ms (#{on_mb} MB peak), " <>
        "#{count.("weighted")} weighted + #{count.("cardinality")} cardinality records, " <>
        "#{byte_size(text)} bytes (#{byte_size(:zlib.gzip(text))} gzipped)"
    else
      line
    end

  IO.puts(line)
end
