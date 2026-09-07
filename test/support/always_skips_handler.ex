defmodule Homelab.Support.AlwaysSkipsHandler do
  @moduledoc """
  A step handler that always declines, compiled to a `.beam` of its own.

  Used by the runner test that purges a handler to prove `skip?/2` is still consulted
  after the module has been unloaded — which needs a module that can be loaded back.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  @impl true
  def skip?(_step, _ctx), do: {:skip, "this handler never has anything to do"}

  @impl true
  def run(_step, _ctx), do: {:ok, %{"ran" => true}}
end
