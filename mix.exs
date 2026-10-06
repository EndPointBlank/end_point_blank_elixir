defmodule EndPointBlankElixir.MixProject do
  use Mix.Project

  @version "0.11.1"

  def project do
    [
      app: :end_point_blank_elixir,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      description:
        "Elixir and Phoenix SDK for EndPointBlank: authorize service-to-service API calls, " <>
          "report endpoint versions, and see which clients still call deprecated API versions.",
      homepage_url: "https://endpointblank.com",
      source_url: "https://github.com/EndPointBlank/end_point_blank_elixir",
      package: package(),
      deps: deps()
    ]
  end

  # Published to the PUBLIC hex.pm repository. The Publish workflow runs
  # `mix hex.publish --yes` with no `--organization`, so every GitHub Release
  # lands on the public index. Consumers depend on it with
  # `{:end_point_blank_elixir, "~> 0.7.0"}` — patch-level, because this project
  # ships breaking changes in minor releases.
  defp package do
    [
      # Proprietary. `LicenseRef-Proprietary` is the SPDX custom-license-ref
      # syntax; Hex warns it isn't a listed identifier, but a `licenses` entry
      # is required for the build.
      licenses: ["LicenseRef-Proprietary"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{
        "Homepage" => "https://endpointblank.com",
        "Documentation" => "https://endpointblank.com/docs/sdk-setup",
        "Source" => "https://github.com/EndPointBlank/end_point_blank_elixir",
        "Issues" => "https://github.com/EndPointBlank/end_point_blank_elixir/issues"
      }
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
