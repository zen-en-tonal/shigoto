defmodule Shigoto do
  @moduledoc """
  """

  defmacro __using__(opts) do
    quote do
      use Shigoto.Base, unquote(opts)
      import Shigoto, only: [inputs: 1]
    end
  end

  @doc """
  Shorthand for declaring multiple workflow inputs as a keyword list.

      inputs [
        order_id: :uuid,
        ordered_at: :datetime
      ]

  Expands to individual `input/2` calls.
  """
  defmacro inputs(pairs) when is_list(pairs) do
    Enum.map(pairs, fn {name, type} ->
      quote do
        input(unquote(name), unquote(type))
      end
    end)
  end
end
