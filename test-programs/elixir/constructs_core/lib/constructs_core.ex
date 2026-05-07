defmodule ConstructsCore do
  @moduledoc false

  defstruct [:id, :name, flags: [], profile: %{}]

  def main do
    pattern_score = pattern_matrix()
    access_score = access_matrix()
    branch_score = branch_matrix(18)
    defaults_score = defaults_matrix(5)
    guard_score = classify(17)
    binary_guard_score = classify("core")
    private_score = private_offset(6)

    final_total =
      pattern_score + access_score + branch_score + defaults_score + guard_score +
        binary_guard_score + private_score

    IO.puts("constructs-core-ok:#{final_total}")
    final_total
  end

  def defaults_matrix(value, bias \\ 3, scale \\ 2) do
    value * scale + bias
  end

  def classify(value) when is_integer(value) and value > 10 do
    value + 100
  end

  def classify(value) when is_binary(value) do
    byte_size(value) + 200
  end

  def classify(_value) do
    300
  end

  def pattern_matrix do
    [list_head, _, list_third | list_rest] = [10, 20, 30, 40, 50]
    %{left: map_left, nested: %{score: nested_score}} = %{left: 21, nested: %{score: 5}}
    <<binary_prefix::binary-size(2), binary_digit, binary_tail::binary>> = "ct7core"

    base_struct = %__MODULE__{
      id: 7,
      name: "core",
      flags: [:active, :traced],
      profile: %{zip: 4242}
    }

    %__MODULE__{id: struct_id, profile: %{zip: struct_zip}} = base_struct

    {:wrap, [nested_head | _], %{deep: %{value: nested_value}}} =
      {:wrap, [3, 4], %{deep: %{value: 9}}}

    pinned_tag = :core

    pin_score =
      case {:ok, :core, 8} do
        {:ok, ^pinned_tag, pinned_amount} when pinned_amount > 0 -> pinned_amount
        _ -> 0
      end

    list_result = list_head + list_third + length(list_rest)
    map_result = map_left + nested_score
    binary_result = byte_size(binary_prefix) + binary_digit + byte_size(binary_tail)
    struct_result = struct_id + div(struct_zip, 1000)
    nested_result = nested_head + nested_value

    list_result + map_result + binary_result + struct_result + nested_result + pin_score
  end

  def access_matrix do
    base_map = %{left: 21, right: 22, nested: %{score: 5, count: 2}}
    updated_map = %{base_map | right: 23}
    map_left = updated_map.left
    nested_score = get_in(updated_map, [:nested, :score])
    put_map = put_in(updated_map, [:nested, :extra], 8)
    update_map = update_in(put_map, [:nested, :count], &(&1 + 5))

    access_total =
      map_left + updated_map.right + nested_score + get_in(update_map, [:nested, :count])

    base_struct = %__MODULE__{id: 11, name: "draft", profile: %{score: 12}}
    updated_struct = %{base_struct | name: "final", profile: %{base_struct.profile | score: 13}}
    struct_id = updated_struct.id
    struct_score = updated_struct.profile.score

    access_total + struct_id + struct_score
  end

  def branch_matrix(input) do
    case_score =
      case branch_input(input) do
        {:ok, value} when value > 10 -> value
        {:ok, value} -> value + 1
        _ -> 0
      end

    cond_score =
      cond do
        input > 20 -> 1
        rem(input, 2) == 0 -> 2
        true -> 3
      end

    if_score =
      if input > 15 do
        4
      else
        5
      end

    unless_score =
      unless input < 0 do
        6
      else
        7
      end

    with_success = with_matrix(:ok)
    with_else = with_matrix(:missing)

    case_score + cond_score + if_score + unless_score + with_success + with_else
  end

  def with_matrix(flag) do
    with {:ok, left} <- fetch_piece(flag, :left),
         {:ok, right} when right > 0 <- fetch_piece(flag, :right) do
      left + right
    else
      {:error, :missing} -> 9
      _ -> 1
    end
  end

  def branch_input(value), do: {:ok, value}

  def fetch_piece(:ok, :left), do: {:ok, 12}
  def fetch_piece(:ok, :right), do: {:ok, 13}
  def fetch_piece(_, _), do: {:error, :missing}

  defp private_offset(value) when is_integer(value) do
    value + 30
  end
end
