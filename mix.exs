defmodule Shigoto.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :shigoto,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: "Declarative DSL for defining domain workflow specifications",
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{},
      files: ~w(lib guides mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/dsl_reference.md": [title: "DSL Reference"],
        "guides/executor.md": [title: "Executor"],
        "guides/persistence.md": [title: "Persistence"],
        "guides/automation.md": [title: "Automation"],
        "guides/diagrams.md": [title: "Diagram Generation"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\//
      ],
      groups_for_modules: [
        DSL: [Shigoto, Shigoto.Dsl],
        Runtime: [Shigoto.Executor, Shigoto.Automation, Shigoto.Multi],
        Export: [Shigoto.Export.Mermaid],
        "Internals & Query API": [Shigoto.Info, Shigoto.IR, Shigoto.Graph]
      ]
    ]
  end

  defp deps do
    [
      {:spark, "~> 2.7.1"},
      {:ecto, "~> 3.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
