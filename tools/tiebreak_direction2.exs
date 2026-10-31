# VCL4THP Q33, direction 2: tournaments made by FIDE's own generator
# (TieBreakServer's tournamentgenerator.py), their tie-breaks and final ranks
# computed by Ainalrami and checked against TieBreakServer's tiebreakchecker.
# Direction 1 - Ainalrami's generator - is tools/tiebreak_direction1.exs.
#
#     elixir tools/tiebreak_direction2.exs --batches 500 --size 100 --workers 2 \
#         --work DIR --state direction2_state.json
#
# Batch b uses setup b % len(setups) and seeds b*size .. (b+1)*size-1 (the
# generator seeds from the file number), so every tournament is distinct and
# a rerun of a batch is the same batch. Resumable: finished batches are in the
# state file. A batch that agrees is deleted; one that does not is kept.
#
# --random-lists SEED: each tournament is ranked under its own random
# tie-break list (tools/tiebreak_random_list.exs; no Buchholz family in the
# round robins) and the values of the codes in it are compared, instead of
# the setups' fixed lists. --first-batch moves the generator seeds: the
# fixed-list run of 2026-09-23 used batches 0-499 (seeds 0-49,999), the
# random-list run of 2026-09-25 batches 2000 on (seeds 200,000 on).
# --strict: exit 1 if any batch errored or disagreed (CI; see
# .github/workflows/tiebreak-check.yml).
#
# Env: TBS_DIR (default ../TieBreakServer), TBS_PYTHON; `mix` on PATH. The
# driver itself needs no compiled project, so `elixir` is enough to start it.

Code.require_file("chunk_runner.exs", __DIR__)
Code.require_file("tiebreak_batches.exs", __DIR__)

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [first_batch: :integer] ++ TiebreakBatches.common_switches()
  )

tbs = System.get_env("TBS_DIR") || Path.join(TiebreakBatches.root(), "../TieBreakServer")
swiss_rank = "BH/C1 BH SB DE"
rr_codes = "PTS SB SB/C1 KS KS/L1 PS WIN WON BPG BWG REP STD ARO/U1000 TPR/U1000 PTP/U1000"
rr_rank = "DE SB KS"
rr_args = ["--rr", "--codes", rr_codes, "--rank", rr_rank]

# {name, generator args, compare args}
setups = [
  {"swiss40x9", ~w(-p 40 -N 9), ["--rank", swiss_rank]},
  {"swiss16x7", ~w(-p 16 -N 7), ["--rank", swiss_rank]},
  {"swiss100x11", ~w(-p 100 -N 11), ["--rank", swiss_rank]},
  {"swiss64x9-unplayed", ~w(-p 64 -N 9 -S 0.03 0.10 0.08), ["--rank", swiss_rank]},
  # No accelerated setup: TieBreakServer 1.9.57's generator raises KeyError
  # 'gamePoints' in get_accelerated with -a, before any file is written.
  {"rr10", ~w(-p 10 -N 9 -m berger), rr_args},
  {"rr9", ~w(-p 9 -N 9 -m berger), rr_args}
]

batches = Keyword.get(opts, :batches, 500)
size = Keyword.get(opts, :size, 100)
first_batch = Keyword.get(opts, :first_batch, 0)
random_lists = Keyword.get(opts, :random_lists)
work = Path.expand(Keyword.get(opts, :work) || raise("--work DIR is required"))
state = Keyword.get(opts, :state) || raise "--state FILE is required"

run_batch = fn b ->
  {name, gen_args, cmp_args} = Enum.at(setups, rem(b, length(setups)))
  d = Path.join(work, "b" <> String.pad_leading(Integer.to_string(b), 5, "0") <> "-" <> name)
  File.rm_rf!(d)
  extra = %{"setup" => name}

  gen =
    ["tournamentgenerator.py", "-g", "#{b * size}", "#{size}"] ++
      gen_args ++ ["-F", "TRF", "-o", Path.join(d, "t%d.trf")]

  case System.cmd(TiebreakBatches.python(), gen, cd: tbs, stderr_to_stdout: true) do
    {_, 0} ->
      cmp_args =
        case random_lists do
          nil -> cmp_args
          seed -> (if "--rr" in cmp_args, do: ["--rr"], else: []) ++ ["--random-lists", "#{seed}"]
        end

      cmp = TiebreakBatches.mix_run(["tools/tiebreak_compare.exs"] ++ cmp_args ++ ["--dir", d])
      TiebreakBatches.settle(b, extra, d, cmp, fn bad, skipped -> bad > 0 or skipped > 0 end)

    {out, _} ->
      Map.merge(%{"batch" => b, "error" => "generator: " <> ChunkRunner.tail(out, 300)}, extra)
  end
end

TiebreakBatches.drive(Enum.to_list(first_batch..(first_batch + batches - 1)//1), batches, run_batch,
  state: state,
  workers: Keyword.get(opts, :workers, 2),
  work: work,
  strict: opts[:strict]
)
