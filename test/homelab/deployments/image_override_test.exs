defmodule Homelab.Deployments.ImageOverrideTest do
  @moduledoc """
  The per-deployment image override: resolution, validation, and the invariant that
  makes it worth having — one deployment moving version must not move any other.
  """
  # Not async: pins :base_domain in application env (see setup).
  use ExUnit.Case, async: false

  alias Homelab.Deployments.{Access, Deployment, SpecBuilder}

  # SpecBuilder reaches Config.base_domain/0, which falls through to Settings and the DB
  # when no app-env override is set. These tests have no sandbox connection, so pin it
  # rather than depending on another file having done so.
  setup do
    previous = Application.get_env(:homelab, :base_domain)
    Application.put_env(:homelab, :base_domain, "test.local")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:homelab, :base_domain, previous),
        else: Application.delete_env(:homelab, :base_domain)
    end)

    :ok
  end

  defp tenant do
    %Homelab.Tenants.Tenant{id: 1, slug: "friends", name: "Friends", status: :active, settings: %{}}
  end

  defp template(overrides \\ %{}) do
    Map.merge(
      %Homelab.Catalog.AppTemplate{
        id: 1,
        slug: "gitlab",
        name: "GitLab",
        version: "16.11.0",
        image: "gitlab/gitlab-ce:16.11.0",
        exposure_mode: :sso_protected,
        auth_integration: true,
        default_env: %{},
        required_env: [],
        volumes: [],
        ports: [%{"container" => 80, "protocol" => "tcp"}],
        resource_limits: %{},
        health_check: %{},
        depends_on: [],
        source: "seeded"
      },
      overrides
    )
  end

  defp deployment(overrides \\ %{}) do
    t = template()

    Map.merge(
      %Deployment{
        id: 1,
        tenant: tenant(),
        tenant_id: 1,
        app_template: t,
        app_template_id: t.id,
        status: :running,
        domain: "gitlab.homelab.local",
        env_overrides: %{},
        extra_routes: [],
        proxy_options: %{}
      },
      overrides
    )
  end

  describe "Access.effective_image/1" do
    test "inherits the template's image when no override is set" do
      assert Access.effective_image(deployment()) == "gitlab/gitlab-ce:16.11.0"
    end

    test "the override wins" do
      d = deployment(%{image_override: "gitlab/gitlab-ce:17.0.0"})
      assert Access.effective_image(d) == "gitlab/gitlab-ce:17.0.0"
    end

    test "image_overridden?/1 distinguishes pinned from following the catalog" do
      refute Access.image_overridden?(deployment())
      assert Access.image_overridden?(deployment(%{image_override: "gitlab/gitlab-ce:17.0.0"}))
    end
  end

  describe "SpecBuilder.build/1" do
    test "an overridden image is what reaches the daemon" do
      d = deployment(%{image_override: "gitlab/gitlab-ce:17.0.0"})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.image == "gitlab/gitlab-ce:17.0.0"
    end

    test "a nil override still yields the template's image" do
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.image == "gitlab/gitlab-ce:16.11.0"
    end

    test "an override does not leak to a sibling deployment of the same template" do
      # The whole reason the override lives on the deployment rather than the shared
      # template: upgrading one space must not upgrade every other space running the
      # same app.
      shared = template()

      upgraded =
        deployment(%{id: 1, app_template: shared, image_override: "gitlab/gitlab-ce:17.0.0"})

      untouched =
        deployment(%{
          id: 2,
          app_template: shared,
          tenant: %{tenant() | id: 2, slug: "work"},
          tenant_id: 2
        })

      assert {:ok, upgraded_spec} = SpecBuilder.build(upgraded)
      assert {:ok, untouched_spec} = SpecBuilder.build(untouched)

      assert upgraded_spec.image == "gitlab/gitlab-ce:17.0.0"
      assert untouched_spec.image == "gitlab/gitlab-ce:16.11.0"
    end
  end

  describe "SpecBuilder image_source" do
    test "a catalog deployment must pull from a registry" do
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.image_source == :registry
    end

    test "an adopted deployment may fall back to the local image" do
      # An adopted container is by definition already running its image; there may be
      # no registry that ever had it.
      d = deployment(%{app_template: template(%{source: "adopted"})})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.image_source == :local
    end

    test "a Workbench-built deployment may fall back to the local image" do
      d = deployment(%{app_template: template(%{source: "built"})})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.image_source == :local
    end

    test "a compose import must pull from a registry" do
      d = deployment(%{app_template: template(%{source: "compose"})})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.image_source == :registry
    end

    test "an explicit override forces a registry pull even for an adopted app" do
      # The rule that makes the version picker trustworthy: an operator who named a
      # ref wants THAT ref, and a stale local image reported as an upgrade is the
      # exact failure this feature exists to fix.
      d =
        deployment(%{
          app_template: template(%{source: "adopted"}),
          image_override: "gitlab/gitlab-ce:17.0.0"
        })

      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.image_source == :registry
      assert spec.image == "gitlab/gitlab-ce:17.0.0"
    end
  end

  describe "changeset validation" do
    defp change(attrs), do: Deployment.changeset(%Deployment{}, base_attrs(attrs))

    defp base_attrs(attrs), do: Map.merge(%{tenant_id: 1, app_template_id: 1}, attrs)

    test "accepts a well-formed reference" do
      cs = change(%{image_override: "ghcr.io/hotio/sonarr:release"})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :image_override) == "ghcr.io/hotio/sonarr:release"
    end

    test "trims surrounding whitespace" do
      cs = change(%{image_override: "  nginx:1.25  "})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :image_override) == "nginx:1.25"
    end

    test "a blank field means inherit, not a blank image" do
      # An emptied form field must clear the override. Storing "" would hand the
      # daemon an empty image string.
      cs = Deployment.changeset(%Deployment{image_override: "nginx:1.25"}, base_attrs(%{image_override: ""}))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :image_override) == nil
    end

    test "rejects a reference with whitespace inside it" do
      cs = change(%{image_override: "nginx 1.25"})
      refute cs.valid?
      assert %{image_override: ["is not a valid image reference"]} = errors_on(cs)
    end

    test "rejects a reference with no name component" do
      cs = change(%{image_override: "ghcr.io/"})
      refute cs.valid?
    end

    defp errors_on(changeset) do
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
    end
  end
end
