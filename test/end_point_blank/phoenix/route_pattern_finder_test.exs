defmodule EndPointBlank.Phoenix.RoutePatternFinderTest do
  @moduledoc """
  Intake matches authorization requests against registered endpoints by exact
  path. A live request carries `/books/17`, but what was registered is
  `/books/:id` — resolving one to the other is what keeps every request to a
  parameterised route from looking like an unregistered endpoint.
  """
  use ExUnit.Case, async: true

  alias EndPointBlank.Phoenix.RoutePatternFinder

  defmodule Router do
    def __routes__ do
      [
        %{verb: :get, path: "/", plug: PageController, plug_opts: :home},
        %{verb: :get, path: "/books", plug: BooksController, plug_opts: :index},
        %{verb: :post, path: "/books", plug: BooksController, plug_opts: :create},
        %{verb: :get, path: "/books/:id", plug: BooksController, plug_opts: :show},
        %{verb: :delete, path: "/books/:id", plug: BooksController, plug_opts: :delete},
        %{
          verb: :get,
          path: "/authors/:author_id/books/:id",
          plug: BooksController,
          plug_opts: :nested
        }
      ]
    end
  end

  defp find(method, path), do: RoutePatternFinder.find(Plug.Test.conn(method, path), Router)

  test "returns a literal route unchanged" do
    assert find("GET", "/books") == "/books"
  end

  test "resolves a concrete path back to its parameterised pattern" do
    assert find("GET", "/books/17") == "/books/:id"
  end

  test "resolves every parameter in a nested pattern" do
    assert find("GET", "/authors/9/books/17") == "/authors/:author_id/books/:id"
  end

  test "distinguishes routes that share a path but not a method" do
    # /books and POST /books are separate endpoints with separate grants.
    assert find("POST", "/books") == "/books"
    assert find("DELETE", "/books/17") == "/books/:id"
  end

  test "falls back to the literal request path when no route matches" do
    assert find("GET", "/not-a-route") == "/not-a-route"
  end

  test "does not match a path with a different number of segments" do
    assert find("GET", "/books/17/pages") == "/books/17/pages"
  end

  test "does not match a method the router does not serve for that path" do
    assert find("PUT", "/books/17") == "/books/17"
  end

  test "matches a route at the root path" do
    assert find("GET", "/") == "/"
  end
end
