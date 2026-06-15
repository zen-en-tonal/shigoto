defmodule Shigoto.Base do
  use Spark.Dsl,
    default_extensions: [
      extensions: [Shigoto.Dsl]
    ]
end
