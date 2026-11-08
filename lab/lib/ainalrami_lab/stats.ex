defmodule AinalramiLab.Stats do
  @moduledoc """
  The arithmetic of the report, and nothing clever.

    * A mean with a 95% interval: `mean ± 1.96 · sd / √n` (the normal
      approximation; with the 100+ tournaments a run uses, the t
      correction is below the rounding).
    * A baseline-variant difference is the mean of the **paired**
      per-tournament differences, with the same interval on those. The
      pairing is real: both arms of a tournament share a seed and, by
      `AinalramiLab.Tournament`'s common random numbers, every game they
      have in common.
    * A proportion with Wilson's 95% score interval, which behaves at 0
      and at small counts where the normal one does not.
  """

  @z 1.959963984540054

  @doc "`%{n:, mean:, lo:, hi:}` for a list of numbers."
  def mean_ci([]), do: %{n: 0, mean: 0.0, lo: 0.0, hi: 0.0}

  def mean_ci(xs) do
    n = length(xs)
    m = Enum.sum(xs) / n

    half =
      if n < 2 do
        0.0
      else
        var = Enum.reduce(xs, 0.0, fn x, acc -> acc + (x - m) * (x - m) end) / (n - 1)
        @z * :math.sqrt(var / n)
      end

    %{n: n, mean: m, lo: m - half, hi: m + half}
  end

  @doc "Paired difference `b - a` of two equally long lists."
  def paired_diff(a, b) when length(a) == length(b),
    do: mean_ci(Enum.zip_with(a, b, fn x, y -> y - x end))

  @doc "`%{k:, n:, p:, lo:, hi:}`, proportions in [0, 1], Wilson interval."
  def wilson(_k, 0), do: %{k: 0, n: 0, p: 0.0, lo: 0.0, hi: 0.0}

  def wilson(k, n) do
    p = k / n
    z2 = @z * @z
    den = 1 + z2 / n
    centre = (p + z2 / (2 * n)) / den
    half = @z * :math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / den
    lo = if k == 0, do: 0.0, else: max(centre - half, 0.0)
    hi = if k == n, do: 1.0, else: min(centre + half, 1.0)
    %{k: k, n: n, p: p, lo: lo, hi: hi}
  end

  @doc "Does a paired interval exclude zero?"
  def significant?(%{lo: lo, hi: hi}), do: lo > 0 or hi < 0
end
