defmodule Homelab.Deployments.Datastore.ConnectionTest do
  @moduledoc """
  What a client is actually told to connect to.

  Every assertion here is a detail that produces a misleading error when wrong: the port
  is not the database's, the sslmode is not optional, and the engine has to be one whose
  TLS negotiation Traefik implements.
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Datastore.Connection

  defp deployment(overrides \\ %{}, template_overrides \\ %{}) do
    template =
      Map.merge(
        %Homelab.Catalog.AppTemplate{
          id: 1,
          slug: "postgres",
          name: "Postgres",
          image: "postgres:17-alpine",
          default_env: %{"POSTGRES_USER" => "homelab", "HOMELAB_DATABASES" => "sonarr,radarr"},
          exposure_mode: :service
        },
        template_overrides
      )

    Map.merge(
      %Homelab.Deployments.Deployment{
        id: 1,
        app_template: template,
        app_template_id: template.id,
        env_overrides: %{},
        tcp_routes: [%{"host" => "postgres-media.example.com", "port" => 5432}]
      },
      overrides
    )
  end

  test "one connection per declared database" do
    connections = Connection.for_deployment(deployment())

    assert Enum.map(connections, & &1.database) == ["sonarr", "radarr"]
  end

  # The port is the ENTRYPOINT's, not the database's. Nothing is listening on 5432 at
  # that hostname.
  test "the client port is 443, not the container port" do
    [conn | _] = Connection.for_deployment(deployment())

    assert conn.port == 443
    assert conn.url =~ ":443/"
    refute conn.url =~ "5432"
  end

  # Without TLS the client sends no server name, matches no TCP router, and falls through
  # to the HTTP routers on the same entrypoint.
  test "the url demands certificate verification" do
    [conn | _] = Connection.for_deployment(deployment())

    assert conn.url =~ "sslmode=verify-full"
  end

  test "the admin user comes from the env, not a guess" do
    [conn | _] = Connection.for_deployment(deployment())

    assert conn.user == "homelab"
    assert conn.url =~ "postgresql://homelab@postgres-media.example.com"
  end

  test "an env override wins over the template default" do
    [conn | _] =
      Connection.for_deployment(deployment(%{env_overrides: %{"POSTGRES_USER" => "app"}}))

    assert conn.user == "app"
  end

  test "every route is crossed with every database" do
    connections =
      Connection.for_deployment(
        deployment(%{
          tcp_routes: [
            %{"host" => "a.example.com", "port" => 5432},
            %{"host" => "b.example.com", "port" => 5432}
          ]
        })
      )

    assert length(connections) == 4
  end

  test "no TCP routes means nothing to connect to" do
    assert Connection.for_deployment(deployment(%{tcp_routes: []})) == []
  end

  test "no declared databases means nothing to connect with" do
    assert Connection.for_deployment(deployment(%{}, %{default_env: %{}})) == []
  end

  # Traefik implements the Postgres STARTTLS negotiation specifically. MySQL's equivalent
  # is not implemented, so a rendered string would simply fail to connect.
  test "a MySQL datastore renders nothing rather than a string that cannot work" do
    assert Connection.for_deployment(
             deployment(%{}, %{
               image: "mariadb:11",
               default_env: %{"MARIADB_DATABASE" => "app"}
             })
           ) == []
  end

  test "an engine homelab does not drive at all renders nothing" do
    assert Connection.for_deployment(deployment(%{}, %{image: "redis:7"})) == []
  end
end
