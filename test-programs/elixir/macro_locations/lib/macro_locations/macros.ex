defmodule MacroLocations.Macros do
  @moduledoc false

  defmacro defmapped(name, value) do
    quote location: :keep do
      def unquote(name)() do
        local_from_macro = unquote(value)
        local_from_macro + 1
      end
    end
  end
end
