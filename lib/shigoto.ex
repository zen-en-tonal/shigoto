defmodule Shigoto do
  @moduledoc """
  """

  defmacro __using__(opts) do
    quote do
      use Shigoto.Base, unquote(opts)
    end
  end
end
