defmodule Shigoto.Info do
  use Spark.InfoGenerator,
    extension: Shigoto.Dsl,
    sections: [:events, :workflows, :automations]
end
