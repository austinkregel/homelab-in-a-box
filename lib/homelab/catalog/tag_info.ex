defmodule Homelab.Catalog.TagInfo do
  @moduledoc "Tag metadata returned by registry drivers."

  @type t :: %__MODULE__{}

  defstruct [:tag, :digest, :last_updated, :size_bytes, architectures: []]
end
