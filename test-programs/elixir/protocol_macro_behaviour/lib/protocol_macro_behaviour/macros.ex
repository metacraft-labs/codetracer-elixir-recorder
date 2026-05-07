defmodule ProtocolMacroBehaviour.Imported do
  @moduledoc false

  def imported_bonus(value) do
    value * 2 + 1
  end
end

defmodule ProtocolMacroBehaviour.Macros do
  @moduledoc false

  defmacro defgenerated(name, values, opts) do
    offset = Keyword.fetch!(opts, :offset)
    generated_values = Enum.map(values, &Macro.escape/1)

    quote location: :keep do
      def unquote(name)(input) do
        hygiene_probe = input * 1000
        generated_values = [unquote_splicing(generated_values)]
        generated_sum = Enum.sum(generated_values)
        unquoted_offset = unquote(offset)
        var!(macro_shared) = generated_sum + unquoted_offset + input
        hygiene_score = hygiene_probe - input * 1000
        var!(macro_shared) + hygiene_score
      end
    end
  end

  defmacro bind_with_hygiene(input) do
    quote do
      local_binding = unquote(input) * 10
      local_binding + unquote(input) + 59
    end
  end
end

defmodule ProtocolMacroBehaviour.UseFeature do
  @moduledoc false

  defmacro __using__(opts) do
    default_bias = Keyword.fetch!(opts, :default_bias)

    quote bind_quoted: [default_bias: default_bias] do
      @behaviour ProtocolMacroBehaviour.Worker
      @runtime_bias default_bias

      import ProtocolMacroBehaviour.Imported, only: [imported_bonus: 1]

      @impl ProtocolMacroBehaviour.Worker
      def perform(value) do
        imported_bonus(value) + @runtime_bias
      end

      def overridable_score(value) do
        value + @runtime_bias
      end

      defoverridable perform: 1, overridable_score: 1
    end
  end
end
