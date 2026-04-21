defmodule EndPointBlank.UnauthorizedError do
  @moduledoc "Raised when an authorization check fails."
  defexception [:message]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{message: Keyword.get(opts, :message, "Unauthorized")}
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end
end
