defmodule OriginalGenerated do
  @moduledoc false

  def compute do
    a = 40
    b = 2
    a + b
  end

  def main do
    result = compute()
    IO.puts("mapped-ok:#{result}")
    result
  end
end
