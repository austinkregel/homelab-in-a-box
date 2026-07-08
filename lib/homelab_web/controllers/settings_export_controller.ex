defmodule HomelabWeb.SettingsExportController do
  use HomelabWeb, :controller

  @doc """
  Downloads the instance's non-encrypted settings as a JSON file. Encrypted
  secrets are deliberately excluded (they can't round-trip safely).
  """
  def export(conn, _params) do
    payload = %{
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "settings" => Homelab.Settings.export_all(),
      "enabled_catalogs" => Enum.map(Homelab.Config.application_catalogs(), & &1.driver_id())
    }

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="homelab-config.json"))
    |> send_resp(200, Jason.encode!(payload, pretty: true))
  end
end
