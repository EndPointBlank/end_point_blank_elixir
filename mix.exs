defmodule EndPointBlankElixir.MixProject do
  use Mix.Project

  @version "0.3.1"

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
  # `{:end_point_blank_elixir, "~> 0.3", organization: "<org>"}`.
  defp package do
    [
      # Proprietary. `LicenseRef-Proprietary` is the SPDX custom-license-ref
      # syntax; Hex warns it isn't a listed identifier, but a `licenses` entry
      # is required for the build, and this is only ever published privately.
      licenses: ["LicenseRef-Proprietary"],
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
      {:jason, "~> 1.2"},
      # Dev-only: lets `mix hex.publish` build + publish docs (and `mix docs`).
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
