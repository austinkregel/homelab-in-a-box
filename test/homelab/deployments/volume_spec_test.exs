defmodule Homelab.Deployments.VolumeSpecTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Homelab.Deployments.VolumeSpec

  defp changeset(volumes) do
    {%{}, %{volumes: {:array, :map}}}
    |> cast(%{volumes: volumes}, [:volumes])
    |> VolumeSpec.validate_changeset(:volumes)
  end

  defp errors(changeset), do: Enum.map(changeset.errors, fn {_f, {msg, _}} -> msg end)

  describe "normalize/1" do
    test "an explicit type is never second-guessed" do
      assert VolumeSpec.normalize(%{
               "container_path" => "/data",
               "type" => "bind",
               "source" => "/srv/x"
             })[
               "type"
             ] == "bind"

      # A named volume MAY carry a source: it is the volume's name, not a path. Adoption
      # writes exactly this, and inferring "bind" from it would mount the wrong thing.
      assert VolumeSpec.normalize(%{
               "container_path" => "/data",
               "type" => "volume",
               "source" => "homelab-managed-pg"
             })["type"] == "volume"
    end

    test "type is inferred from the SHAPE of source, matching SpecBuilder's rule" do
      # Absolute path -> a host folder.
      assert VolumeSpec.normalize(%{"container_path" => "/data", "source" => "/srv/x"})["type"] ==
               "bind"

      # A bare word is a volume NAME, which is precisely how Docker reads it. Inferring
      # "bind" here is what would silently mount an empty volume.
      assert VolumeSpec.normalize(%{"container_path" => "/data", "source" => "pgdata"})["type"] ==
               "volume"

      # No source at all -> managed, name derived downstream from the mount path.
      assert VolumeSpec.normalize(%{"container_path" => "/data"})["type"] == "volume"
    end

    test "accepts the legacy path and target keys for the mount path" do
      assert VolumeSpec.normalize(%{"path" => "/data"})["container_path"] == "/data"
      assert VolumeSpec.normalize(%{"target" => "/data"})["container_path"] == "/data"
    end

    test "blanks become nil, so a half-filled row cannot masquerade as a real source" do
      vol =
        VolumeSpec.normalize(%{"container_path" => "/data", "type" => "bind", "source" => "  "})

      assert vol["source"] == nil
      # ...and it stays a bind, so validation rejects it rather than quietly downgrading
      # it to a managed volume the operator never asked for.
      assert vol["type"] == "bind"
    end
  end

  describe "parse/1 vs parse_rows/1" do
    test "parse drops blank rows; parse_rows keeps them for a live form" do
      params = %{
        "0" => %{"container_path" => "/data"},
        "1" => %{"container_path" => ""}
      }

      assert [%{"container_path" => "/data"}] = VolumeSpec.parse(params)
      assert length(VolumeSpec.parse_rows(params)) == 2
    end

    test "indexed params keep form order, not map order" do
      params = %{
        "10" => %{"container_path" => "/ten"},
        "2" => %{"container_path" => "/two"},
        "1" => %{"container_path" => "/one"}
      }

      assert Enum.map(VolumeSpec.parse(params), & &1["container_path"]) ==
               ["/one", "/two", "/ten"]
    end
  end

  describe "validate_changeset/2" do
    test "accepts a folder mount with an absolute host path" do
      cs =
        changeset([
          %{"container_path" => "/var/www/storage", "type" => "bind", "source" => "/srv/app"}
        ])

      assert cs.valid?
    end

    test "rejects a folder mount whose source is a bare name" do
      cs = changeset([%{"container_path" => "/data", "type" => "bind", "source" => "appdata"}])

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "absolute host path"))
    end

    test "rejects a folder mount with no source at all" do
      cs = changeset([%{"container_path" => "/data", "type" => "bind"}])

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "absolute host path"))
    end

    test "rejects a relative mount path" do
      cs = changeset([%{"container_path" => "data"}])

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "must be absolute"))
    end

    test "rejects two volumes at the same mount path" do
      cs =
        changeset([
          %{"container_path" => "/data"},
          %{"container_path" => "/data", "type" => "bind", "source" => "/srv/other"}
        ])

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "same path"))
    end

    test "a managed volume needs no source" do
      assert changeset([%{"container_path" => "/data"}]).valid?
    end
  end
end
