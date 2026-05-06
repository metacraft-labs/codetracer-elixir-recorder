defmodule MacroLocations do
  @moduledoc false

  require MacroLocations.Macros

  MacroLocations.Macros.defmapped(:generated_answer, 41)

  def main do
    result = generated_answer()
    IO.puts("macro-ok:#{result}")
    result
  end
end
