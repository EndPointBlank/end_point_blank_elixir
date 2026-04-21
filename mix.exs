defmodule EndPointBlankElixir.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :end_point_blank_elixir,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
