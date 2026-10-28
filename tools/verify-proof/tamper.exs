# Tamper tests for the pairing-proof verifier.
#
#   elixir tools/verify-proof/tamper.exs PROOF_FILE
#
# Takes the first round certificate in PROOF_FILE that has a solve with a
# matched edge, checks that the verifier passes it untouched, then makes
# one small change at a time and checks that the verifier FAILS each one:
#
#   weight   - a matched edge's weight raised by 1 (the edge is no longer
#              tight, so the dual no longer proves the matching optimal)
#   dual     - a matched vertex's dual raised by 1 (same, from the other side)
#   unmatch  - one pair removed from the matching (a vertex with a positive
#              dual is left exposed, and the weights no longer add up)
#   rematch  - two pairs' partners swapped, (a, b) (c, d) -> (a, c) (b, d)
#              (a pair that is not an edge, or not a tight one)
#   set      - a blossom's dual raised by 2, when the solve has one
#
# Exits 0 when the untouched certificate passes and every tamper is caught,
# 1 otherwise. Like verify.exs, standard library only and no engine code.

Process.put(:verify_proof_as_library, true)
Code.require_file(Path.join(__DIR__, "verify.exs"))

defmodule TamperProof do
  # `{name, tampered_line}` for every tamper that applies to `line`.
  def tampers(line) do
    doc = JSON.decode!(line)
    {index, solve} = target(doc)
    [[a, b] | rest] = solve["matching"]

    edit = fn fun -> JSON.encode!(update_in(doc, ["solves"], &List.update_at(&1, index, fun))) end

    weight =
      edit.(fn s ->
        w = weight_of(doc["solves"], s, a, b)
        put_edge(s, a, b, Integer.to_string(String.to_integer(w) + 1))
      end)

    dual =
      edit.(fn s ->
        y = Enum.find_value(s["duals"], "0", fn [v, y] -> if v == a, do: y end)
        others = Enum.reject(s["duals"], fn [v, _] -> v == a end)
        %{s | "duals" => [[a, Integer.to_string(String.to_integer(y) + 1)] | others]}
      end)

    unmatch = edit.(fn s -> %{s | "matching" => rest} end)

    rematch =
      case rest do
        [[c, d] | more] ->
          [{"rematch", edit.(fn s -> %{s | "matching" => [[a, c], [b, d] | more]} end)}]

        _ ->
          []
      end

    set =
      case solve["sets"] do
        [first | others] ->
          z = Integer.to_string(String.to_integer(first["z"]) + 2)
          [{"set", edit.(fn s -> %{s | "sets" => [%{first | "z" => z} | others]} end)}]

        _ ->
          []
      end

    [{"weight", weight}, {"dual", dual}, {"unmatch", unmatch}] ++ rematch ++ set
  end

  # The first solve with a matched edge whose graph is given in full, so a
  # changed weight is changed at its source.
  defp target(doc) do
    doc["solves"]
    |> Enum.with_index()
    |> Enum.find_value(fn {s, i} ->
      if s["matching"] != [] and Map.has_key?(s["graph"], "edges"), do: {i, s}
    end) || raise "no solve with a matched edge and a full graph in this round"
  end

  defp weight_of(_solves, s, a, b) do
    {u, v} = {min(a, b), max(a, b)}
    Enum.find_value(s["graph"]["edges"], fn [x, y, w] -> if {x, y} == {u, v}, do: w end)
  end

  defp put_edge(s, a, b, w) do
    {u, v} = {min(a, b), max(a, b)}

    edges =
      Enum.map(s["graph"]["edges"], fn
        [^u, ^v, _] -> [u, v, w]
        e -> e
      end)

    put_in(s, ["graph", "edges"], edges)
  end

  def failed?(line) do
    case VerifyProof.verify_line(line) do
      {:ok, r} -> Enum.any?(r.solves, fn {_, _, v} -> v != :pass end)
      {:error, _} -> true
    end
  end

  def main([path]) do
    line =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find(fn l -> Enum.any?(JSON.decode!(l)["solves"], &(&1["matching"] != [])) end)

    clean = not failed?(line)

    IO.puts(
      "untouched: " <>
        if(clean, do: "PASS (as it should)", else: "FAIL - the file is bad to begin with")
    )

    caught =
      for {name, tampered} <- tampers(line) do
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
