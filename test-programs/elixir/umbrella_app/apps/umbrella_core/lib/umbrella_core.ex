defmodule UmbrellaCore do
  @moduledoc false

  def compute(value) do
    local = value + 5
    local * 3
  end

  def main do
    result = compute(9)
    IO.puts("umbrella-core:#{result}")
    result
  end
end
