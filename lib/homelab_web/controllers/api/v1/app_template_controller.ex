defmodule HomelabWeb.Api.V1.AppTemplateController do
  use HomelabWeb, :controller

  alias Homelab.Catalog

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, _params) do
    templates = Catalog.list_app_templates()
    render(conn, :index, app_templates: templates)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, template} <- Catalog.get_app_template(id) do
      render(conn, :show, app_template: template)
    end
  end
end
