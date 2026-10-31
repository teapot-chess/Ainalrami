defmodule Ainalrami.BursteinBbpTest do
  @moduledoc """
  C.04.4.2 against bbpPairings 6.0.0, the only other program with a
  Burstein mode, used two ways:

    * **the seeding rounds**, an exact oracle: 1.6 pairs them by the Dutch
      system, and `bbpPairings --dutch` is an independent Dutch engine, so
      every seeding round `Ainalrami.Burstein` pairs must be bbpPairings'
      to the board and the colour;
    * **the later rounds**, a control only: `bbpPairings --burstein`
      implements "a previous version of the Burstein system" (its README),
      with an index, an acceleration and an order the 2026 text does not
      have. Differences are counted, never asserted.

  Tagged `:interop` (excluded by default): it runs bbpPairings once per
  round. BURSTEIN_BBP_SEEDS ("a..b", default 1..300) picks the events;
  BURSTEIN_VALIDATION_SIZES the roster sizes (4..10).
  """
  use ExUnit.Case, async: true

  alias Ainalrami.{Burstein, Trf}
  alias Ainalrami.Test.{Bbppairings, BursteinEvents}

  @moduletag :interop
  @moduletag timeout: :infinity

  defp range(var, default) do
    case System.get_env(var) do
      nil ->
        default

      text ->
        [a, b] = text |> String.split("..") |> Enum.map(&String.to_integer/1)
        a..b
    end
  end

  defp trf(players, opts) do
    Trf.serialize(%{
      tournament: %{
        name: "burstein",
        type: "swiss",
        number_of_rounds: opts[:expected_rounds],
        initial_colour: opts[:initial_colour],
        point_system: opts[:point_system],
        forbidden_pairs: opts[:forbidden_pairs]
      },
      players: players
    })
  end

  defp bbp(players, opts, mode) do
    if mode == :dutch do
      Bbppairings.pair(trf(players, opts))
    else
      run(trf(players, opts), "--burstein")
    end
  end

  # `Bbppairings.pair/1` is `--dutch` only; the control run needs `--burstein`.
  defp run(text, flag) do
    dir = Path.join(System.tmp_dir!(), "ainalrami-bb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "in.trf")
    output = Path.join(dir, "out.txt")

    try do
      File.write!(input, text)

      case System.cmd(Bbppairings.exe_path(), [flag, input, "-p", output], stderr_to_stdout: true) do
        {_, 0} ->
          [_ | lines] =
            output |> File.read!() |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))

          {:ok,
           Enum.map(lines, fn l ->
             [w, b] = l |> String.split() |> Enum.map(&String.to_integer/1)
             {w, if(b == 0, do: nil, else: b)}
           end)}

        {out, 1} ->
          {:no_valid_pairing, out}

        {out, code} ->
          {:error, {code, out}}
      end
    after
      File.rm_rf(dir)
    end
  end

  test "seeding rounds are bbpPairings --dutch's; later rounds against --burstein, counted" do
    if not Bbppairings.available?(),
      do: flunk("bbpPairings not found at #{Bbppairings.exe_path()}")

    totals =
      range("BURSTEIN_BBP_SEEDS", 1..300)
      |> Task.async_stream(
        fn seed ->
          c = :counters.new(5, [])

          BursteinEvents.play(seed, range("BURSTEIN_VALIDATION_SIZES", 4..10), fn players,
                                                                                  opts,
                                                                                  round ->
            mine = Burstein.pair_next_round(players, opts)
            seeding? = round <= Burstein.seeding_rounds(opts[:expected_rounds])
            theirs = bbp(players, opts, if(seeding?, do: :dutch, else: :burstein))

            case {seeding?, mine, theirs} do
              {true, {:ok, a}, {:ok, b}} ->
                assert Enum.sort(a) == Enum.sort(b),
                       "seed #{seed}, round #{round}: seeding round differs from bbpPairings --dutch\n" <>
                         "  ours: #{inspect(Enum.sort(a))}\n  bbp:  #{inspect(Enum.sort(b))}"

                :counters.add(c, 1, 1)
                a

              {true, {:error, _}, {:no_valid_pairing, _}} ->
                :counters.add(c, 1, 1)
                :stop

              {true, m, t} ->
                flunk("seed #{seed}, round #{round}: seeding #{inspect(m)} vs #{inspect(t)}")

              {false, {:ok, a}, {:ok, b}} ->
                :counters.add(c, 2, 1)
                if Enum.sort(a) == Enum.sort(b), do: :counters.add(c, 3, 1)
                a

              {false, {:ok, a}, _} ->
                :counters.add(c, 2, 1)
                :counters.add(c, 4, 1)
                a

              {false, {:error, _}, _} ->
                :counters.add(c, 5, 1)
                :stop
            end
          end)

          for i <- 1..5, do: :counters.get(c, i)
        end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.reduce([0, 0, 0, 0, 0], fn {:ok, l}, acc -> Enum.zip_with(l, acc, &+/2) end)

    [seeding, later, same, bbp_refused, we_refused] = totals

    IO.puts(
      "\nBURSTEINBBP seeding=#{seeding} later=#{later} same_as_old_burstein=#{same} " <>
        "bbp_refused=#{bbp_refused} we_refused=#{we_refused}"
    )

    assert seeding > 0
  end
end
