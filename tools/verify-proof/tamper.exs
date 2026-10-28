# Tamper tests for the pairing-proof verifier.
#
#   elixir tools/verify-proof/tamper.exs PROOF_FILE
#
# Checks that the verifier passes PROOF_FILE untouched, then makes one small
# change at a time - each one either breaks a certificate or makes a claim
# false - and checks that the verifier FAILS every one. A verifier that says
# yes to everything passes the first half of that and nothing else.
#
# On the first weighted record with a matched edge and its graph in full:
#
#   weight          a matched edge's weight raised by 1 (no longer tight)
#   dual            a matched vertex's dual raised by 1 (same, other side)
#   unmatch         one pair removed from the matching
#   rematch         two pairs' partners swapped, (a, b) (c, d) -> (a, c) (b, d)
#   set             a blossom's dual raised by 2, when there is one
#
# On the cardinality records, where the proof has one of the kind:
#
#   false-maximum   a "maximum" matching with a pair taken out: no longer
#                   maximum, so no barrier can show it is
#   false-blocked   an "augment" turned into "blocked", with the path's
#                   inner vertices as the barrier: a path exists, so no
#                   barrier can rule one out
#   false-augment   a "blocked" turned into "augment" along a made-up path
#   exposable-plus  a vertex outside the exposable set added to it
#   exposable-minus a vertex of it taken out
#
# On what was published:
#
#   read            a read pair's second vertex moved to another one
#   published       two published pairs' partners swapped
#   dropped         a published board split into two byes: its pair was
#                   read off a matching, and is no longer published
#
# Exits 0 when the untouched proof passes and every tamper is caught, 1
# otherwise. Like verify.exs: standard library only, no engine code.

Process.put(:verify_proof_as_library, true)
Code.require_file(Path.join(__DIR__, "verify.exs"))

defmodule TamperProof do
  @doc "`{name, tampered text}` for every tamper that applies to `text`."
  def tampers(text) do
    docs = text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    Enum.flat_map(
      [&weighted/1, &cardinality/1, &published/1],
      fn tamper -> tamper.(docs) end
    )
  end

  defp edit(docs, index, fun) do
    docs |> List.update_at(index, fun) |> Enum.map_join("\n", &JSON.encode!/1)
  end

  defp first(docs, pred) do
    docs |> Enum.with_index() |> Enum.find(fn {d, _} -> pred.(d) end)
  end

  defp weighted(docs) do
    case first(docs, fn d ->
           d["type"] == "weighted" and d["matching"] != [] and
             Map.has_key?(d["graph"], "edges")
         end) do
      nil ->
        []

      {solve, index} ->
        [[a, b] | rest] = solve["matching"]
        edit = &edit(docs, index, &1)

        weight =
          edit.(fn s ->
            {u, v} = {min(a, b), max(a, b)}

            edges =
              Enum.map(s["graph"]["edges"], fn
                [^u, ^v, w] -> [u, v, Integer.to_string(String.to_integer(w) + 1)]
                e -> e
              end)

            put_in(s, ["graph", "edges"], edges)
          end)

        dual =
          edit.(fn s ->
            y = Enum.find_value(s["duals"], "0", fn [v, y] -> if v == a, do: y end)
            others = Enum.reject(s["duals"], fn [v, _] -> v == a end)
            %{s | "duals" => [[a, Integer.to_string(String.to_integer(y) + 1)] | others]}
          end)

        rematch =
          case rest do
            [[c, d] | more] ->
              [{"rematch", edit.(fn s -> %{s | "matching" => [[a, c], [b, d] | more]} end)}]

            _ ->
              []
          end

        set =
          case solve["sets"] do
            [s1 | others] ->
              z = Integer.to_string(String.to_integer(s1["z"]) + 2)
              [{"set", edit.(fn s -> %{s | "sets" => [%{s1 | "z" => z} | others]} end)}]

            _ ->
              []
          end

        [
          {"weight", weight},
          {"dual", dual},
          {"unmatch", edit.(fn s -> %{s | "matching" => rest} end)}
        ] ++ rematch ++ set
    end
  end

  defp cardinality(docs) do
    claim = fn c -> &(&1["type"] == "cardinality" and &1["claim"] == c) end

    maximum =
      case first(docs, fn d -> claim.("maximum").(d) and d["matching"] != [] end) do
        nil ->
          []

        {_, i} ->
          [{"false-maximum", edit(docs, i, &Map.update!(&1, "matching", fn m -> tl(m) end))}]
      end

    blocked =
      case first(docs, claim.("augment")) do
        nil ->
          []

        {d, i} ->
          inner = d["path"] |> Enum.drop(1) |> Enum.take_every(2) |> Enum.drop(-1)

          [
            {"false-blocked",
             edit(docs, i, &Map.merge(&1, %{"claim" => "blocked", "barrier" => inner}))}
          ]
      end

    augment =
      case first(docs, claim.("blocked")) do
        nil ->
          []

        {d, i} ->
          # Some vertex next to nothing in particular: any path is made up.
          other = rem(d["root"] + 1, d["n"])

          [
            {"false-augment",
             edit(docs, i, &Map.merge(&1, %{"claim" => "augment", "path" => [d["root"], other]}))}
          ]
      end

    exposable =
      case first(docs, claim.("exposable")) do
        nil ->
          []

        {d, i} ->
          outside = Enum.find(0..(d["n"] - 1)//1, &(&1 not in d["exposable"]))

          plus =
            if outside,
              do: [
                {"exposable-plus",
                 edit(
                   docs,
                   i,
                   &Map.update!(&1, "exposable", fn e -> Enum.sort([outside | e]) end)
                 )}
              ],
              else: []

          minus = [
            {"exposable-minus", edit(docs, i, &Map.update!(&1, "exposable", fn e -> tl(e) end))}
          ]

          plus ++ minus
      end

    maximum ++ blocked ++ augment ++ exposable
  end

  defp published(docs) do
    read =
      case first(docs, fn d -> d["type"] == "read" and d["pairs"] != [] end) do
        nil ->
          []

        {_, i} ->
          [
            {"read",
             edit(docs, i, fn d ->
               [[u, v, a, b] | rest] = d["pairs"]
               %{d | "pairs" => [[u, v + 1, a, b] | rest]}
             end)}
          ]
      end

    pub =
      case first(docs, fn d ->
             d["type"] == "round" and
               length(Enum.filter(d["round"]["pairs"] || [], &match?([_, b] when b != nil, &1))) >=
                 2
           end) do
        nil ->
          []

        {d, i} ->
          {[[a, b], [c, e]], others} =
            Enum.split_with(d["round"]["pairs"], &match?([_, x] when x != nil, &1))
            |> then(fn {two, rest} -> {Enum.take(two, 2), Enum.drop(two, 2) ++ rest} end)

          [
            {"published",
             edit(docs, i, &put_in(&1, ["round", "pairs"], [[a, c], [b, e] | others]))}
          ]
      end

    # A published board dropped: its pair was read, and is now not published.
    drop =
      case first(docs, fn d ->
             d["type"] == "round" and Enum.any?(d["round"]["pairs"] || [], &match?([_, b] when b != nil, &1))
           end) do
        nil ->
          []

        {d, i} ->
          [[a, b] | _] = Enum.filter(d["round"]["pairs"], &match?([_, x] when x != nil, &1))
          rest = List.delete(d["round"]["pairs"], [a, b])
          [{"dropped", edit(docs, i, &put_in(&1, ["round", "pairs"], [[a, nil], [b, nil] | rest]))}]
      end

    read ++ pub ++ drop
  end

  @doc "Whether the verifier fails anything in `text`."
  def failed?(text) do
    rounds = VerifyProof.verify_text(text)
    rounds == [] or Enum.any?(rounds, &(&1.verdict != :pass))
  end

  def main([path]) do
    {:ok, device} = File.open(path, [:read, :binary, :compressed])
    text = IO.binread(device, :eof)
    File.close(device)

    clean = not failed?(text)

    IO.puts(
      "untouched: " <>
        if(clean, do: "PASS (as it should)", else: "FAIL - the file is bad to begin with")
    )

    caught =
      for {name, tampered} <- tampers(text) do
        failed = failed?(tampered)
        IO.puts("#{name}: " <> if(failed, do: "FAIL (caught)", else: "PASS - NOT CAUGHT"))
        failed
      end

    if clean and Enum.all?(caught), do: 0, else: 1
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir tamper.exs PROOF_FILE")
    2
  end
end

unless Process.get(:tamper_proof_as_library) do
  System.halt(TamperProof.main(System.argv()))
end
