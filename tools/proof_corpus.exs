# The pairing proofs' corpus: every round of a few thousand fuzz
# tournaments paired with the proof option off and on, the two pairings
# compared, and every certificate checked by the independent verifier
# (`tools/verify-proof/verify.exs`, loaded as a library - it shares no code
# with the engine, and reads the certificate only as the JSON text the
# engine wrote).
#
#   MIX_ENV=test mix run tools/proof_corpus.exs DIR [AXIS,AXIS...]
#
# Writes DIR/<axis>.tsv, one line per round:
#
#   axis seed round players off_us on_us bytes solves failed agrees same
#   uncertified
#
# `same` is the published pairing with the option on against the one with
# it off (they must be equal: the option may not change a pairing); `agrees`
# is the certificate's own statement that the reference path paired the
# round the same way; `failed` the solves the verifier failed; `uncertified`
# the engine's decisions in the round no certificate covers. A round with a
# failed solve, a disagreement or a difference has its certificate kept as
# DIR/fail-<axis>-<seed>-<round>.jsonl, and the first round of each axis
# with a solve in it as DIR/sample-<axis>.jsonl, for the verifier run
# standalone. The tournaments are `Ainalrami.Test.FuzzTournament`'s, as for
# `tools/perf_diff.exs`, played forward on the pairing with the option off.

alias Ainalrami.Pairing
alias Ainalrami.Test.FuzzTournament, as: Fuzz

Process.put(:verify_proof_as_library, true)
Code.require_file(Path.join([__DIR__, "verify-proof", "verify.exs"]))

defmodule ProofCorpus do
  alias Ainalrami.Pairing
  alias Ainalrami.Test.FuzzTournament, as: Fuzz

  # label, first seed, tournaments, rounds asked, concurrency, knobs
  @axes [
    {"p_small", 1, 1500, 9, nil,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "4",
       "PAIRING_FUZZ_MAX_PLAYERS" => "40",
       "PAIRING_FUZZ_BYE_PCT" => "8",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_WITHDRAW_PCT" => "2",
       "PAIRING_FUZZ_LATE_PCT" => "5"
     }},
    {"p_mixed", 20_001, 1000, 9, nil,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "6",
       "PAIRING_FUZZ_MAX_PLAYERS" => "150",
       "PAIRING_FUZZ_BYE_PCT" => "5",
       "PAIRING_FUZZ_FORFEIT_PCT" => "4",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "5",
       "PAIRING_FUZZ_ACCEL" => "mixed",
       "PAIRING_FUZZ_POINT_SYSTEM" => "mixed",
       "PAIRING_FUZZ_INITIAL_COLOUR" => "mixed",
       "PAIRING_FUZZ_RATING_MODE" => "mixed"
     }},
    {"p_tiny", 40_001, 500, 9, nil,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "4",
       "PAIRING_FUZZ_MAX_PLAYERS" => "12",
       "PAIRING_FUZZ_ROUNDS_MAX" => "11",
       "PAIRING_FUZZ_BYE_PCT" => "10",
       "PAIRING_FUZZ_FORFEIT_PCT" => "5",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "8"
     }},
    {"p_150_300", 60_001, 40, 5, 8,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "150",
       "PAIRING_FUZZ_MAX_PLAYERS" => "300",
       "PAIRING_FUZZ_BYE_PCT" => "4",
       "PAIRING_FUZZ_FORFEIT_PCT" => "3",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1",
       "PAIRING_FUZZ_ACCEL" => "mixed"
     }},
    {"p_400_1000", 80_001, 12, 3, 2,
     %{
       "PAIRING_FUZZ_MIN_PLAYERS" => "400",
       "PAIRING_FUZZ_MAX_PLAYERS" => "1000",
       "PAIRING_FUZZ_BYE_PCT" => "3",
       "PAIRING_FUZZ_FORFEIT_PCT" => "2",
       "PAIRING_FUZZ_FORBIDDEN_PCT" => "1"
     }}
  ]

  def axes, do: @axes

  def tournament(axis, seed, rounds_asked, range, dir) do
    {rounds, player_count, forbidden, roster} = Fuzz.begin!(seed, rounds_asked, range)

    {lines, _} =
      Enum.reduce_while(1..rounds, {[], roster}, fn round, {acc, players} ->
        Fuzz.withdraw_some(round, player_count)
        {active, pending} = Fuzz.reveal_late_entrants(players, round)
        active = Fuzz.assign_requested_byes(active)

        opts = [
          expected_rounds: rounds,
          forbidden_pairs: forbidden,
          initial_colour: String.downcase(Fuzz.initial_colour()),
          point_system: Fuzz.point_system()
        ]

        {off_us, off} = :timer.tc(fn -> pair(active, opts) end)

        {on_us, on} =
          :timer.tc(fn ->
            Process.delete(:proof_line)
            pair(active, opts ++ [proof: &Process.put(:proof_line, &1)])
          end)

        line = Process.delete(:proof_line)
        {verdict, solves, failed, agrees, uncertified} = verify(line)
        same = off == on

        if failed > 0 or not agrees or not same or verdict != :ok do
          File.write!(Path.join(dir, "fail-#{axis}-#{seed}-#{round}.jsonl"), [line || "", "\n"])
        end

        if solves > 0 and not File.exists?(Path.join(dir, "sample-#{axis}.jsonl")) do
          File.write!(Path.join(dir, "sample-#{axis}.jsonl"), [line, "\n"])
        end

        row = [
          axis,
          seed,
          round,
          length(active),
          off_us,
          on_us,
          if(line, do: byte_size(line), else: 0),
          solves,
          failed,
          agrees,
          same,
          uncertified
        ]

        case off do
          {:ok, pairs} ->
            next = Fuzz.apply_round(active, pairs, Fuzz.simulate_results(pairs))
            {:cont, {[row | acc], next ++ pending}}

          _ ->
            {:halt, {[row | acc], players}}
        end
      end)

    Enum.reverse(lines)
  end

  defp pair(players, opts) do
    {:ok, Pairing.pair_next_round(players, opts)}
  rescue
    e in Pairing.NoValidPairingError -> {:refused, e.reason}
  end

  defp verify(nil), do: {:missing, 0, 1, false, 0}

  defp verify(line) do
    case VerifyProof.verify_line(line) do
      {:ok, r} ->
        failed = Enum.count(r.solves, fn {_, _, v} -> v != :pass end)
        agrees = String.contains?(line, ~s("agrees":true))
        uncertified = r.uncertified |> Map.values() |> Enum.sum()
        {:ok, length(r.solves), failed, agrees, uncertified}

      {:error, _} ->
        {:unreadable, 0, 1, false, 0}
    end
  end
end

[dir | rest] = System.argv()
File.mkdir_p!(dir)

only =
  case rest do
    [list] -> String.split(list, ",", trim: true)
    _ -> nil
  end

Ainalrami.Log.set_level(:quiet)
Application.put_env(:ainalrami, :log_level, :quiet)

for {axis, from, count, rounds, conc, knobs} <- ProofCorpus.axes(), only == nil or axis in only do
  count = min(count, String.to_integer(System.get_env("PROOF_LIMIT", "1000000")))
  Enum.each(knobs, fn {k, v} -> System.put_env(k, v) end)

  range =
    String.to_integer(knobs["PAIRING_FUZZ_MIN_PLAYERS"])..String.to_integer(
      knobs["PAIRING_FUZZ_MAX_PLAYERS"]
    )

  out = Path.join(dir, "#{axis}.tsv")
  started = System.monotonic_time(:millisecond)

  rows =
    from..(from + count - 1)
    |> Task.async_stream(fn seed -> ProofCorpus.tournament(axis, seed, rounds, range, dir) end,
      max_concurrency: conc || System.schedulers_online(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, rows} -> rows end)

  File.write!(out, Enum.map(rows, &[Enum.join(&1, "\t"), "\n"]))
  Enum.each(knobs, fn {k, _} -> System.delete_env(k) end)

  bad =
    Enum.count(rows, fn [_, _, _, _, _, _, _, _, failed, agrees, same, _] ->
      failed > 0 or not agrees or not same
    end)

  solves = rows |> Enum.map(&Enum.at(&1, 7)) |> Enum.sum()
  secs = (System.monotonic_time(:millisecond) - started) / 1000

  IO.puts(
    "#{axis}: #{count} tournaments, #{length(rows)} rounds, #{solves} solves verified, " <>
      "#{bad} bad round(s) in #{Float.round(secs, 1)} s -> #{out}"
  )
end
