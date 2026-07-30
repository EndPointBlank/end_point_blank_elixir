defmodule EndPointBlank.Phoenix.Versioned do
  @moduledoc """
  Macro that adds per-action version metadata to a Phoenix controller.

  ## Usage

      defmodule MyAppWeb.BooksController do
        use Phoenix.Controller
        use EndPointBlank.Phoenix.Versioned

        version_of :index, ["v1", "v2"]
        version_of :index, ["v0"]

        def index(conn, _params), do: ...
      end

  Lifecycle state (Current, Deprecated, ...) is **not** declared here. It is
  managed in the EndPointBlank portal, where changing it does not require
  shipping code. This reports which versions an action serves, and nothing about
  what they mean.

  Multiple calls for the same action merge, deduplicated, in declaration order.

  The registered metadata is read by `EndPointBlank.Phoenix.EndpointRegistrar`
  when it builds the endpoint list sent to the EndPointBlank API at startup.
  """

  defmacro __using__(_opts) do
    quote do
      import EndPointBlank.Phoenix.Versioned, only: [version_of: 2]
      Module.register_attribute(__MODULE__, :epb_action_versions, accumulate: false)
      @epb_action_versions %{}
      @before_compile EndPointBlank.Phoenix.Versioned
    end
  end

  @doc """
  Declares which versions `action` serves. Stores an `%{action => [versions]}`
  map, merging with any prior declaration for the same action.
  """
  defmacro version_of(action, versions) do
    quote do
      @epb_action_versions EndPointBlank.Phoenix.Versioned.__merge__(
                             @epb_action_versions,
                             unquote(action),
                             unquote(versions)
                           )
    end
  end

  @doc false
  # Enum.uniq keeps declaration order, so the manifest stays stable between
  # deploys instead of churning.
  def __merge__(action_versions, action, versions) when is_list(versions) do
    Map.update(action_versions, action, Enum.uniq(versions), fn prior ->
      Enum.uniq(prior ++ versions)
    end)
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __epb_versions__, do: @epb_action_versions
    end
  end
end
