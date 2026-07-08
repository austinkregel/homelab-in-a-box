defmodule HomelabWeb.SettingsExportControllerTest do
  use HomelabWeb.ConnCase, async: false

  setup do
    on_exit(fn ->
      Homelab.Settings.evict("instance_name")
      Homelab.Settings.evict("oidc_client_secret")
    end)

    :ok
  end

  test "exports non-encrypted settings and excludes secrets", %{conn: conn} do
    {:ok, _} = Homelab.Settings.set("instance_name", "MyLab")
    {:ok, _} = Homelab.Settings.set("oidc_client_secret", "top-secret", encrypt: true)

    conn = get(conn, ~p"/settings/export")

    assert response_content_type(conn, :json)
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "homelab-config.json"

    body = Jason.decode!(response(conn, 200))
    assert body["settings"]["instance_name"] == "MyLab"
    refute Map.has_key?(body["settings"], "oidc_client_secret")
    assert is_list(body["enabled_catalogs"])
  end
end
