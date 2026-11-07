defmodule AinalramiLab.Variant do
  @moduledoc """
  A rule variant: the C.04.3 (2026) quality criteria in some order, some
  of them perhaps dropped, plus a handful of parameters and alternative
  readings. `baseline/0` is the 2026 text as `AinalramiVerify.Bracket`
  reads it, and nothing else.

  A variant is written as operations joined by `+`:

  | operation | effect |
  |---|---|
  | `baseline` | nothing (the 2026 text) |
  | `drop:C12` or `drop:C12,C13` | remove criteria from 3.8.1's comparison |
  | `move:C14:before:C10`, `move:C14:after:C21` | reorder |
  | `swap:C10:C12` | exchange two criteria's places |
  | `absolute_cd=N` | 1.7.1: a preference is absolute when \\|CD\\| > N (text: 1) |
  | `streak=N` | 1.7.1: absolute after the same colour N times running (text: 2) |
  | `float_memory=N` | rounds of float history C14-C21 look back on: 1, 2 (text) or 3 |
  | `c525=arrival\\|tpn\\|initial` | 5.2.5's number: the arrival numbering (the SPP's 2026-08-27 reading, the baseline), the TPN, or no parity at all (the higher-ranked player always takes the initial colour) |
  | `c18=limbo\\|paired` | [C18]/[C20]: count an MDP left in the Limbo (the baseline reading) or only MDPs paired here |
  | `c13=strong_or_absolute\\|strong_only` | [C13]: which denied preferences count |
  | `c3=on\\|off` | [C3]: non-topscorers with the same absolute preference may not meet |
  | `rematches=forbidden\\|allowed` | [C1]: allowing rematches is not a proposal; it prices [C1] |

  Operations apply left to right.
  """

  @quality ~w(C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20 C21)
  # Criteria that exist only with float_memory=3: the C16/C17/C20/C21
  # families one round further back, placed after C21.
  @memory3 ~w(C16@3 C17@3 C20@3 C21@3)
  @memory2 ~w(C16 C17 C20 C21)

  defstruct name: "baseline",
            order: @quality,
            absolute_cd: 1,
            streak: 2,
            float_memory: 2,
            c525: :arrival,
            c18: :limbo,
            c13: :strong_or_absolute,
            c3: :on,
            rematches: :forbidden

  @type t :: %__MODULE__{}

  def quality_criteria, do: @quality
  def all_criteria, do: @quality ++ @memory3

  def baseline, do: %__MODULE__{}

  @doc "Is this variant the 2026 text?"
  def baseline?(%__MODULE__{} = v), do: %{v | name: "baseline"} == baseline()

  @doc "Parse a variant string. Raises `ArgumentError` on anything it does not know."
  def parse(spec) when is_binary(spec) do
    spec = String.trim(spec)

    ops =
      spec
      |> String.split("+", trim: true)
      |> Enum.map(&String.trim/1)

    v = Enum.reduce(ops, baseline(), &apply_op/2)
    %{v | name: if(spec == "", do: "baseline", else: spec)}
  end

  defp apply_op("baseline", v), do: v

  defp apply_op("drop:" <> list, v) do
    names = list |> String.split(",", trim: true) |> Enum.map(&criterion!/1)
    Enum.each(names, &present!(v, &1))
    %{v | order: v.order -- names}
  end

  defp apply_op("move:" <> rest, v) do
    case String.split(rest, ":") do
      [c, where, anchor] when where in ["before", "after"] ->
        c = criterion!(c)
        anchor = criterion!(anchor)
        present!(v, c)
        present!(v, anchor)
        if c == anchor, do: raise(ArgumentError, "cannot move #{c} relative to itself")
        without = List.delete(v.order, c)
        i = Enum.find_index(without, &(&1 == anchor))
        i = if where == "after", do: i + 1, else: i
        %{v | order: List.insert_at(without, i, c)}

      _ ->
        raise ArgumentError, "move:C:before:D or move:C:after:D, got move:#{rest}"
    end
  end

  defp apply_op("swap:" <> rest, v) do
    case String.split(rest, ":") do
      [a, b] ->
        a = criterion!(a)
        b = criterion!(b)
        present!(v, a)
        present!(v, b)

        order =
          Enum.map(v.order, fn
            ^a -> b
            ^b -> a
            x -> x
          end)

        %{v | order: order}

      _ ->
        raise ArgumentError, "swap:C:D, got swap:#{rest}"
    end
  end

  defp apply_op(op, v) do
    case String.split(op, "=", parts: 2) do
      [key, value] -> param(key, value, v)
      _ -> raise ArgumentError, "unknown variant operation #{inspect(op)}"
    end
  end

  defp param("absolute_cd", value, v), do: %{v | absolute_cd: int!(value, 1, 8)}
  defp param("streak", value, v), do: %{v | streak: int!(value, 2, 8)}

  defp param("float_memory", value, v) do
    case int!(value, 1, 3) do
      1 -> %{v | float_memory: 1, order: (v.order -- @memory2) -- @memory3}
      2 -> %{v | float_memory: 2, order: v.order -- @memory3}
      3 -> %{v | float_memory: 3, order: (v.order -- @memory3) ++ @memory3}
    end
  end

  defp param("c525", value, v), do: %{v | c525: choice!(value, ~w(arrival tpn initial))}
  defp param("c18", value, v), do: %{v | c18: choice!(value, ~w(limbo paired))}
  defp param("c13", value, v), do: %{v | c13: choice!(value, ~w(strong_or_absolute strong_only))}
  defp param("c3", value, v), do: %{v | c3: choice!(value, ~w(on off))}
  defp param("rematches", value, v), do: %{v | rematches: choice!(value, ~w(forbidden allowed))}
  defp param(key, _, _), do: raise(ArgumentError, "unknown variant parameter #{inspect(key)}")

  defp criterion!(name) do
    up = String.upcase(String.trim(name))

    if up in all_criteria(),
      do: up,
      else:
        raise(
          ArgumentError,
          "unknown criterion #{inspect(name)}; known: #{Enum.join(@quality, " ")}"
        )
  end

  defp present!(v, c) do
    if c not in v.order, do: raise(ArgumentError, "#{c} is not in this variant's order")
  end

  defp int!(s, lo, hi) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= lo and n <= hi -> n
      _ -> raise ArgumentError, "expected an integer #{lo}..#{hi}, got #{inspect(s)}"
    end
  end

  defp choice!(s, allowed) do
    s = String.trim(s)

    if s in allowed,
      do: String.to_atom(s),
      else: raise(ArgumentError, "expected one of #{Enum.join(allowed, ", ")}, got #{inspect(s)}")
  end

  @doc "A one-line description of what differs from the baseline."
  def describe(%__MODULE__{} = v) do
    b = baseline()

    order =
      cond do
        v.order == b.order -> []
        true -> ["order " <> Enum.join(v.order, " ")]
      end

    params =
      for k <- [:absolute_cd, :streak, :float_memory, :c525, :c18, :c13, :c3, :rematches],
          Map.fetch!(v, k) != Map.fetch!(b, k),
          do: "#{k}=#{Map.fetch!(v, k)}"

    case order ++ params do
      [] -> "the 2026 text"
      list -> Enum.join(list, "; ")
    end
  end
end
