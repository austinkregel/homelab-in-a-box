defmodule Homelab.Reconciliation.Diff do
  @moduledoc """
  Represents the difference between desired and actual state.
  """

  @type t :: %__MODULE__{
          to_deploy: [map()],
          to_remove: [map()],
          to_restart: [map()],
          to_update: [map()],
          in_sync: [map()]
        }

  defstruct to_deploy: [],
            to_remove: [],
            to_restart: [],
            to_update: [],
            in_sync: []
end
