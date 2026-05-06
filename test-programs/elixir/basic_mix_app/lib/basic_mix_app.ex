defmodule BasicMixApp do
  @moduledoc false

  def compute(input) do
    base = input + 1
    doubled = base * 2
    doubled + 20
  end

  def main do
    result = compute(10)
    IO.puts("basic-ok:#{result}")
    result
  end
end
