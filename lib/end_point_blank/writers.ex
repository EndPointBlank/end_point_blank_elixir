defmodule EndPointBlank.Writers do
  @moduledoc "Dispatch helper — routes payloads to the direct or delayed writer."

  alias EndPointBlank.Writers.{DirectWriter, DelayedWriter}

  def write(url_key, :direct, payloads), do: DirectWriter.write(url_key, payloads)
  def write(url_key, :delayed, payloads), do: DelayedWriter.write(url_key, payloads)
end
