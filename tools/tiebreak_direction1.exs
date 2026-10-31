# VCL4THP Q33, direction 1: tournaments made by Ainalrami's generator
# (tools/tiebreak_corpus.exs), their tie-breaks and final ranks checked
# against FIDE's TieBreakServer. Direction 2 - TieBreakServer's generator -
# is tools/tiebreak_direction2.exs; the two share the state and log format.
#
#     elixir tools/tiebreak_direction1.exs --batches 380 --size 100 --workers 2 \
#         --first-seed 1000000 --work DIR --state direction1_state.json
#
# Batch b covers seeds first_seed + b*size .. + size - 1. Resumable; a batch
# that agrees is deleted, one that does not is kept with compare.txt.
#
# --random-lists SEED: rank each tournament under its own random tie-break
# list (tools/tiebreak_random_list.exs) and compare the values of the codes
# in it, instead of the fixed list below. Earlier fixed-list runs used seeds
# from 1,000,000; the random-list run of 2026-09-25 used 2,000,000 on.
# --strict: exit 1 if any batch errored or disagreed (CI; see
# .github/workflows/tiebreak-check.yml).
#
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON; `mix` on PATH. The
# driver itself needs no compiled project, so `elixir` is enough to start it.

Code.require_file("chunk_runner.exs", __DIR__)
Code.require_file("tiebreak_batches.exs", __DIR__)

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [first_seed: :integer] ++ TiebreakBatches.common_switches()
  )

batches = Keyword.get(opts, :batches, 380)
size = Keyword.get(opts, :size, 100)
first_seed = Keyword.get(opts, :first_seed, 1_000_000)
random_lists = Keyword.get(opts, :random_lists)
work = Path.expand(Keyword.get(opts, :work) || raise("--work DIR is required"))
state = Keyword.get(opts, :state) || raise "--state FILE is required"
rank = "BH/C1 BH SB DE"

run_batch = fn b ->
  d = Path.join(work, "b" <> String.pad_leading(Integer.to_string(b), 5, "0"))
  File.rm_rf!(d)
  File.mkdir_p!(d)

  case TiebreakBatches.mix_run(["tools/tiebreak_corpus.exs", d, "#{size}", "#{first_seed + b * size}"]) do
    {0, _} ->
      lists = if random_lists, do: ["--random-lists", "#{random_lists}"], else: ["--rank", rank]
      cmp = TiebreakBatches.mix_run(["tools/tiebreak_compare.exs"] ++ lists ++ ["--dir", d])
      TiebreakBatches.settle(b, %{}, d, cmp, fn bad, _skipped -> bad > 0 end)

    {_, out} ->
      %{"batch" => b, "error" => "generator: " <> ChunkRunner.tail(out, 300)}
  end
end

TiebreakBatches.drive(Enum.to_list(0..(batches - 1)//1), batches, run_batch,
  state: state,
  workers: Keyword.get(opts, :workers, 2),
  work: work,
  strict: opts[:strict]
)
