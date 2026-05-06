defmodule CanonicalFlow do
  @moduledoc false

  def compute do
    a = 10
    b = 32
    sum_val = a + b
    doubled = sum_val * 2
    final_result = doubled + a
    true = final_result == 94
    final_result
  end

  def main do
    result = compute()
    true = result == 94
    IO.puts(result)
    result
  end
end
