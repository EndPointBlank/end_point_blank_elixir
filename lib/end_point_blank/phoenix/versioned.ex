defmodule EndPointBlank.Phoenix.Versioned do
  @moduledoc """
  Macro that adds per-action version metadata to a Phoenix controller.

  ## Usage

      defmodule MyAppWeb.BooksController do
        use Phoenix.Controller
        use EndPointBlank.Phoenix.Versioned

        version_of :index, ["v1", "v2"], state: "Current"
        version_of :index, ["v0"],       state: "Deprecated"

        def index(conn, _params), do: ...
      end

  Multiple calls for the same action are merged — repeating a state appends
  (de-duped) versions, and additional states are added alongside the existing
  ones.

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
  Declares version metadata for `action`. Stores it as a nested
  `%{action => %{state => versions}}` map, merging with any prior declaration
  for the same action.

  ## Options
    * `:state` - e.g. `"Current"`, `"Deprecated"`, `"In Development"` (default: `"Current"`)
  """
  defmacro version_of(action, versions, opts \\ []) do
    state = Keyword.get(opts, :state, "Current")

    quote do
      @epb_action_versions EndPointBlank.Phoenix.Versioned.__merge__(
                             @epb_action_versions,
                             unquote(action),
                             unquote(state),
                             unquote(versions)
                           )
    end
  end

  @doc false
  def __merge__(action_versions, action, state, versions) when is_list(versions) do
    Map.update(
      action_versions,
      action,
      %{state => versions},
      fn existing_states ->
        Map.update(
          existing_states,
          state,
          versions,
          fn prior -> Enum.uniq(prior ++ versions) end
        )
      end
    )
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __epb_versions__, do: @epb_action_versions
    end
  end
end
