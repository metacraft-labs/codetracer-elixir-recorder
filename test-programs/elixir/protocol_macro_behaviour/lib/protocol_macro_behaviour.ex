defprotocol ProtocolMacroBehaviour.Renderable do
  @fallback_to_any true

  def label(value)
  def score(value)
end

defimpl ProtocolMacroBehaviour.Renderable, for: Any do
  def label(%module{tag: tag}) do
    "#{inspect(module)}:#{tag}"
  end

  def score(%{base: base}) do
    base + 13
  end
end

defmodule ProtocolMacroBehaviour.ManualItem do
  @moduledoc false

  defstruct [:base, :tag]
end

defmodule ProtocolMacroBehaviour.DerivedItem do
  @moduledoc false

  @derive ProtocolMacroBehaviour.Renderable
  defstruct [:base, :tag]
end

defimpl ProtocolMacroBehaviour.Renderable, for: ProtocolMacroBehaviour.ManualItem do
  def label(%ProtocolMacroBehaviour.ManualItem{tag: tag}) do
    "manual:#{tag}"
  end

  def score(%ProtocolMacroBehaviour.ManualItem{base: base}) do
    base + 5
  end
end

defmodule ProtocolMacroBehaviour.Worker do
  @moduledoc false

  @callback perform(integer()) :: integer()
end

defmodule ProtocolMacroBehaviour.UsingWorker do
  @moduledoc false

  use ProtocolMacroBehaviour.UseFeature, default_bias: 7

  alias ProtocolMacroBehaviour.Imported
  require ProtocolMacroBehaviour.Macros

  @impl ProtocolMacroBehaviour.Worker
  def perform(value) do
    default_score = super(value)
    imported_score = Imported.imported_bonus(value + 1)
    default_score + imported_score + 4
  end

  def overridable_score(value) do
    parent_score = super(value)
    parent_score + 3
  end

  ProtocolMacroBehaviour.Macros.defgenerated(:macro_generated_score, [3, 4, 5], offset: 6)
end

defmodule ProtocolMacroBehaviour do
  @moduledoc false

  alias ProtocolMacroBehaviour.{DerivedItem, ManualItem, Renderable, UsingWorker}

  import ProtocolMacroBehaviour.Imported, only: [imported_bonus: 1]
  require ProtocolMacroBehaviour.Macros

  @runtime_seed 4
  @protocol_items [
    %ManualItem{base: 10, tag: :manual_attr},
    %DerivedItem{base: 20, tag: :derived_attr}
  ]
  @labels [:protocol, :macro, :behaviour]

  def main do
    protocol_score = protocol_matrix()
    macro_score = macro_matrix(6)
    behaviour_score = behaviour_matrix(7)
    attribute_score = attribute_matrix()

    final_total = protocol_score + macro_score + behaviour_score + attribute_score

    IO.puts("protocol-macro-behaviour-ok:#{final_total}")
    final_total
  end

  def protocol_matrix do
    manual_item = %ManualItem{base: 10, tag: :manual}
    derived_item = %DerivedItem{base: 20, tag: :derived}
    protocol_items = [manual_item, derived_item | @protocol_items]

    protocol_scores = Enum.map(protocol_items, &Renderable.score/1)
    manual_score = Renderable.score(manual_item)
    derived_score = Renderable.score(derived_item)

    label_size =
      byte_size(Renderable.label(manual_item)) + byte_size(Renderable.label(derived_item))

    Enum.sum(protocol_scores) + manual_score + derived_score + label_size
  end

  def macro_matrix(input) do
    local_binding = input
    hygiene_score = ProtocolMacroBehaviour.Macros.bind_with_hygiene(input)
    bound_from_macro = hygiene_score - input * 10
    generated_score = UsingWorker.macro_generated_score(input)

    local_binding + bound_from_macro + hygiene_score + generated_score
  end

  def behaviour_matrix(input) do
    perform_score = UsingWorker.perform(input)
    super_score = UsingWorker.overridable_score(input)
    imported_score = imported_bonus(input)

    perform_score + super_score + imported_score
  end

  def attribute_matrix do
    label_count = length(@labels)
    runtime_seed = @runtime_seed
    attr_protocol_score = Enum.sum(Enum.map(@protocol_items, &Renderable.score/1))

    label_count + runtime_seed + attr_protocol_score
  end
end
