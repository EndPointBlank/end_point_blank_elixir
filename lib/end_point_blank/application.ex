defmodule EndPointBlank.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EndPointBlank.Config,
      EndPointBlank.AccessTokens,
      EndPointBlank.Writers.DelayedWriter
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EndPointBlank.Supervisor)
  end
end
