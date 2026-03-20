defmodule HomelabWeb.Api.V1.DeploymentJSON do
  alias Homelab.Deployments.Deployment

  def index(%{deployments: deployments}) do
    %{data: Enum.map(deployments, &data/1)}
  end

  def show(%{deployment: deployment}) do
    %{data: data(deployment)}
  end

  defp data(%Deployment{} = d) do
    %{
      id: d.id,
      status: d.status,
      domain: d.domain,
      external_id: d.external_id,
      tenant_id: d.tenant_id,
      app_template_id: d.app_template_id,
      env_overrides: redact_secrets(d.env_overrides),
      last_reconciled_at: d.last_reconciled_at,
      error_message: d.error_message,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp redact_secrets(nil), do: %{}

  defp redact_secrets(env) do
    Map.new(env, fn {k, v} ->
      if sensitive_key?(k), do: {k, "***REDACTED***"}, else: {k, v}
    end)
  end

  defp sensitive_key?(key) do
    upper = String.upcase(key)

    String.contains?(upper, "PASSWORD") or
      String.contains?(upper, "SECRET") or
      String.contains?(upper, "TOKEN") or
      (String.contains?(upper, "KEY") and not String.contains?(upper, "PUBLIC"))
  end
end
