defmodule ValuesComprehensions do
  @moduledoc false

  defstruct [:name, count: 0, flags: []]

  def main do
    values_score = value_matrix()
    list_score = list_comprehension_matrix()
    binary_score = binary_bitstring_matrix()
    options_score = option_matrix()
    capture_score = capture_matrix()

    final_total = values_score + list_score + binary_score + options_score + capture_score
    IO.puts("values-comprehensions-ok:#{final_total}")
    final_total
  end

  def value_matrix do
    string_value = "trace"
    charlist_value = ~c"beam"
    sigil_string = ~s(sigiled)
    sigil_words = ~w(alpha beta)a
    sigil_regex = ~r/^tr/

    map_value = %{
      string: string_value,
      sigil: sigil_string,
      words: sigil_words
    }

    struct_value = %__MODULE__{
      name: "fixture",
      count: 3,
      flags: [:values, :comprehensions]
    }

    remote_capture = &String.upcase/1
    placeholder_capture = &(&1 + 2)
    captured_string = remote_capture.("ct")
    capture_value = placeholder_capture.(5)

    regex_bonus =
      if Regex.match?(sigil_regex, string_value) do
        11
      else
        0
      end

    byte_size(string_value) + length(charlist_value) + byte_size(sigil_string) +
      length(sigil_words) + map_size(map_value) + struct_value.count +
      byte_size(captured_string) + capture_value + regex_bonus
  end

  def list_comprehension_matrix do
    numbers = [1, 2, 3, 4, 5, 6]
    list_filtered = for n <- numbers, rem(n, 2) == 0, do: n * n

    nested_pairs =
      for x <- [1, 2],
          y <- [3, 4],
          x + y > 4 do
        {x, y, x * y}
      end

    map_gen_list =
      for {key, value} <- %{a: 1, b: 2, c: 3}, value >= 2 do
        {key, value * 10}
      end

    pair_score = Enum.sum(for {_, _, product} <- nested_pairs, do: product)
    map_gen_score = Enum.sum(for {_, value} <- map_gen_list, do: value)

    Enum.sum(list_filtered) + pair_score + map_gen_score
  end

  def binary_bitstring_matrix do
    utf8_binary = "abc"
    <<prefix::binary-size(2), last_byte>> = utf8_binary

    raw_binary = <<0, 255, 65, 5>>
    <<raw_head, raw_tail::binary>> = raw_binary

    bitstring_value = <<5::3, 17::5, 3::2>>
    <<three::3, five::5, two::2>> = bitstring_value

    binary_comprehension =
      for <<byte <- <<1, 2, 3, 4, 5>> >>, rem(byte, 2) == 1, into: <<>> do
        <<byte + 64>>
      end

    bitstring_comprehension =
      for <<bit::1 <- <<0b1011_0110>> >>, bit == 1, into: <<>> do
        <<bit::1>>
      end

    byte_size(prefix) + last_byte + raw_head + byte_size(raw_tail) + three + five + two +
      byte_size(binary_comprehension) + bit_size(bitstring_comprehension)
  end

  def option_matrix do
    into_map =
      for {key, value} <- [a: 1, b: 2, c: 3], value > 1, into: %{} do
        {key, value * 2}
      end

    into_binary =
      for <<byte <- "abc">>, into: <<>> do
        <<byte + 1>>
      end

    reduced_sum =
      for n <- [1, 2, 3, 4], rem(n, 2) == 0, reduce: 10 do
        acc -> acc + n
      end

    unique_values = for n <- [1, 1, 2, 2, 3], uniq: true, do: n * 2

    map_size(into_map) + Enum.sum(Map.values(into_map)) + byte_size(into_binary) +
      reduced_sum + Enum.sum(unique_values)
  end

  def capture_matrix do
    remote_capture = &String.length/1
    placeholder_capture = &(&1 * 3 + &2)
    mapper_capture = &(&1 + 1)

    capture_lengths = for word <- ["alpha", "be"], do: remote_capture.(word)
    capture_values = Enum.map([1, 2, 3], mapper_capture)
    capture_result = placeholder_capture.(4, 5)

    Enum.sum(capture_lengths) + Enum.sum(capture_values) + capture_result
  end
end
