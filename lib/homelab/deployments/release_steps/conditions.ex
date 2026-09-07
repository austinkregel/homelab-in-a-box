defmodule Homelab.Deployments.ReleaseSteps.Conditions do
  @moduledoc """
  Says whether a step runs, in terms of `ReleaseFacts`.

  A condition is `{fact_name, message}`, where the message is what the operator reads
  when that fact is what stopped the step. `all/2` needs every condition; `any/2` needs
  one.
  """

  alias Homelab.Deployments.ReleaseFacts

  @type condition :: {atom(), String.t()}
  @type verdict :: :run | {:skip, String.t()}

  @doc "Runs only when every condition holds; the first failure's message is the reason."
  @spec all(ReleaseFacts.t(), [condition]) :: verdict
  def all(facts, conditions) do
    case Enum.find(conditions, fn {fact, _message} -> not ReleaseFacts.fetch!(facts, fact) end) do
      nil -> :run
      {_fact, message} -> {:skip, message}
    end
  end

  @doc "Runs when at least one condition holds; the reason names all of them."
  @spec any(ReleaseFacts.t(), [condition]) :: verdict
  def any(facts, conditions) do
    if Enum.any?(conditions, fn {fact, _message} -> ReleaseFacts.fetch!(facts, fact) end) do
      :run
    else
      {:skip, Enum.map_join(conditions, "; ", fn {_fact, message} -> message end)}
    end
  end
end
