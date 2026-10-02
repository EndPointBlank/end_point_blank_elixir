defmodule EndPointBlank.Management.Page do
  @moduledoc """
  One page of a management API list: `data`, the items (decoded JSON maps with
  string keys), and `next_cursor`, to pass as `after:` for the next page, or
  `nil` on the last page.

  Lists take `limit:` (1 to 100; the API's default is 50) and `after:`. Each
  resource's `stream` function follows `next_cursor` for you.
  """

  defstruct data: [], next_cursor: nil

  @type t :: %__MODULE__{data: [map()], next_cursor: String.t() | nil}
end
