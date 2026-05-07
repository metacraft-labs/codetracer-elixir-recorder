defprotocol ReferenceEdges.EdgeProtocol do
  def weight(value)
end

defimpl ReferenceEdges.EdgeProtocol, for: Integer do
  def weight(value) do
    value + 3
  end
end

defimpl ReferenceEdges.EdgeProtocol, for: List do
  def weight(values) do
    Enum.sum(values) + length(values)
  end
end

defimpl ReferenceEdges.EdgeProtocol, for: BitString do
  def weight(value) do
    byte_size(value) * 5
  end
end

defmodule ReferenceEdges.Contract do
  @callback required(integer()) :: integer()
  @callback optional(integer()) :: integer()
  @optional_callbacks optional: 1
end

defmodule ReferenceEdges.FullImpl do
  @behaviour ReferenceEdges.Contract

  @impl ReferenceEdges.Contract
  def required(value) do
    value * 2
  end

  @impl ReferenceEdges.Contract
  def optional(value) do
    value + 40
  end
end

defmodule ReferenceEdges.MinimalImpl do
  @behaviour ReferenceEdges.Contract

  @impl ReferenceEdges.Contract
  def required(value) do
    value + 5
  end
end

defmodule ReferenceEdges do
  alias ReferenceEdges.{EdgeProtocol, FullImpl, MinimalImpl}

  defguard is_even_integer(value) when is_integer(value) and rem(value, 2) == 0
  defguardp is_small_positive(value) when is_integer(value) and value > 0 and value < 10

  defmacrop traced_adjust(value, opts) do
    bias = Keyword.fetch!(opts, :bias)

    quote location: :keep do
      unquote(value) * 2 + unquote(bias)
    end
  end

  def main do
    anonymous_score = anonymous_matrix()
    guard_score = guard_matrix()
    macro_score = macro_matrix()
    behaviour_score = behaviour_matrix(6)
    protocol_score = protocol_matrix()

    final_total = anonymous_score + guard_score + macro_score + behaviour_score + protocol_score

    IO.puts("reference-edges-ok:#{final_total}")
    final_total
  end

  def anonymous_matrix do
    classifier = fn
      value when is_even_integer(value) -> value + 10
      value when is_small_positive(value) -> value + 20
      {:tag, value} -> value + 30
      _ -> 0
    end

    even_clause_score = classifier.(4)
    guard_clause_score = classifier.(5)
    tuple_clause_score = classifier.({:tag, 7})
    fallback_clause_score = classifier.(:unused)

    even_clause_score + guard_clause_score + tuple_clause_score + fallback_clause_score
  end

  def guard_matrix do
    public_guard_score =
      if is_even_integer(8) do
        8
      else
        0
      end

    private_guard_score =
      if is_small_positive(6) do
        60
      else
        0
      end

    rejected_private_guard_score =
      if is_small_positive(12) do
        500
      else
        7
      end

    public_guard_score + private_guard_score + rejected_private_guard_score
  end

  def macro_matrix do
    private_macro_score = traced_adjust(9, bias: 11)

    guarded_macro_score =
      case 3 do
        value when is_small_positive(value) -> traced_adjust(value, bias: 4)
        _ -> 0
      end

    private_macro_score + guarded_macro_score
  end

  def behaviour_matrix(input) do
    full_required_score = FullImpl.required(input)
    full_optional_score = optional_or_default(FullImpl, input, 0)
    minimal_required_score = MinimalImpl.required(input)
    minimal_optional_score = optional_or_default(MinimalImpl, input, 13)

    full_required_score + full_optional_score + minimal_required_score + minimal_optional_score
  end

  def protocol_matrix do
    integer_protocol_score = EdgeProtocol.weight(10)
    list_protocol_score = EdgeProtocol.weight([2, 3, 4])
    bitstring_protocol_score = EdgeProtocol.weight("edge")

    integer_protocol_score + list_protocol_score + bitstring_protocol_score
  end

  defp optional_or_default(module, input, default) do
    if function_exported?(module, :optional, 1) do
      module.optional(input)
    else
      default
    end
  end
end
