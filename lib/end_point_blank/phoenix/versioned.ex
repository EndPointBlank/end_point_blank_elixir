defmodule EndPointBlank.Phoenix.Versioned do
  @moduledoc """
  Macro that adds per-action version metadata to a Phoenix controller.

  ## Usage

      defmodule MyAppWeb.BooksController do
        use Phoenix.Controller
        use EndPointBlank.Phoenix.Versioned

        version_of :index, ["1"], state: "Current"

        def index(conn, _params), do: ...
      end

  The registered metadata is read by `EndPointBlank.Phoenix.EndpointRegistrar`
  when it builds the endpoint list sent to the EndPointBlank API at startup.
  """

  defmacro __using__(_opts) do
    quote do
      import EndPointBlank.Phoenix.Versioned, only: [version_of: 2, version_of: 3]
      Module.register_attribute(__MODULE__, :epb_action_versions, accumulate: false)
      @epb_action_versions %{}
      @before_compile EndPointBlank.Phoenix.Versioned
    end
  end

  @doc """
  Declares version metadata for `action`.

  ## Options
    * `:state` - e.g. `"Current"`, `"Deprecated"`, `"In Development"` (default: `"Current"`)
  """
  defmacro version_of(action, versions, opts \\ []) do
    state = Keyword.get(opts, :state, "Current")

    quote do
      @epb_action_versions Map.put(
                             @epb_action_versions,
                             unquote(action),
                             %{versions: unquote(versions), state: unquote(state)}
                           )
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __epb_versions__, do: @epb_action_versions
    end
  end
end
