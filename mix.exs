defmodule EndPointBlankElixir.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :end_point_blank_elixir,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description:
        "EndPointBlank Elixir client library: authorization plus request/response/error/log " <>
          "ingestion (with masking, batching, timeouts, and a bounded queue) — also used for " <>
          "self-monitoring.",
      package: package(),
      deps: deps()
    ]
  end

  # Published to a PRIVATE Hex organization (set the org at publish time:
  # `mix hex.publish --organization <org>`). Consumers depend on it with
  # `{:end_point_blank_elixir, "~> 0.2", organization: "<org>"}`.
  defp package do
    [
      # Proprietary — published only to the private Hex org, so no public
      # SPDX license is declared.
      files: ~w(lib mix.exs README.md),
      links: %{"Source" => "https://github.com/EndPointBlank/end_point_blank_elixir"}
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {EndPointBlank.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.2"}
    ]
  end
end
