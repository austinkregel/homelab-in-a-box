defmodule Homelab.Deployments.RuntimeSpecTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Homelab.Deployments.RuntimeSpec

  defp caps_changeset(caps, opts \\ []) do
    {%{}, %{capabilities: {:array, :string}}}
    |> cast(%{capabilities: caps}, [:capabilities])
    |> RuntimeSpec.validate_capabilities(:capabilities, opts)
  end

  defp devices_changeset(devices) do
    {%{}, %{devices: {:array, :map}}}
    |> cast(%{devices: devices}, [:devices])
    |> RuntimeSpec.validate_devices(:devices)
  end

  defp sysctls_changeset(sysctls) do
    {%{}, %{sysctls: :map}}
    |> cast(%{sysctls: sysctls}, [:sysctls])
    |> RuntimeSpec.validate_sysctls(:sysctls)
  end

  defp errors(changeset), do: Enum.map(changeset.errors, fn {_f, {msg, _}} -> msg end)

  describe "parse_capabilities/1" do
    test "folds the two spellings Docker accepts into one" do
      # A compose file in the wild uses either. Storing both would hand the daemon the
      # same permission twice and make "is NET_ADMIN granted?" un-answerable by lookup.
      assert RuntimeSpec.parse_capabilities(["CAP_NET_ADMIN", "net_admin", " NET_ADMIN "]) ==
               ["NET_ADMIN"]
    end

    test "accepts a comma- or newline-separated string, which is what a textarea posts" do
      assert RuntimeSpec.parse_capabilities("NET_ADMIN\nSYS_MODULE") == [
               "NET_ADMIN",
               "SYS_MODULE"
             ]

      assert RuntimeSpec.parse_capabilities("NET_ADMIN, NET_RAW") == ["NET_ADMIN", "NET_RAW"]
    end

    test "nil and junk are empty, never nil-in-a-list" do
      assert RuntimeSpec.parse_capabilities(nil) == []
      assert RuntimeSpec.parse_capabilities(%{}) == []
      assert RuntimeSpec.parse_capabilities([nil, "", "  "]) == []
    end
  end

  describe "validate_capabilities/3" do
    test "a typo is refused rather than handed to the daemon" do
      # The daemon's own error names the entire capability list rather than the typo,
      # and a capability that was MEANT to be added looks identical to one that never
      # was: the app just fails later with a permission error from inside itself.
      changeset = caps_changeset(["NET_ADMN"])

      refute changeset.valid?
      assert [message] = errors(changeset)
      assert message =~ "NET_ADMN"
    end

    test "a valid capability passes in either spelling" do
      assert caps_changeset(["NET_ADMIN"]).valid?
      assert caps_changeset(["cap_net_admin"]).valid?
    end

    test "ALL is a DROP-only value" do
      # Dropping everything is a hardening move. Adding everything is `privileged` by
      # another name, and this deliberately offers no way to ask for that.
      refute caps_changeset(["ALL"]).valid?
      assert caps_changeset(["ALL"], allow_all: true).valid?
    end
  end

  describe "normalize_device/1" do
    test "understands every compose spelling" do
      assert RuntimeSpec.normalize_device("/dev/net/tun") ==
               %{
                 "host_path" => "/dev/net/tun",
                 "container_path" => "/dev/net/tun",
                 "permissions" => "rwm"
               }

      assert RuntimeSpec.normalize_device("/dev/sda:/dev/xvda") ==
               %{
                 "host_path" => "/dev/sda",
                 "container_path" => "/dev/xvda",
                 "permissions" => "rwm"
               }

      assert RuntimeSpec.normalize_device("/dev/ttyUSB0:/dev/ttyUSB0:rw") ==
               %{
                 "host_path" => "/dev/ttyUSB0",
                 "container_path" => "/dev/ttyUSB0",
                 "permissions" => "rw"
               }
    end

    test "a missing container path defaults to the host path" do
      # Compose's own rule, and what an operator means every time but the rare rename.
      assert RuntimeSpec.normalize_device(%{"host_path" => "/dev/net/tun"})["container_path"] ==
               "/dev/net/tun"
    end

    test "unparseable permissions fall back to full access rather than locking the app out" do
      assert RuntimeSpec.normalize_device(%{"host_path" => "/dev/x", "permissions" => "!!"})[
               "permissions"
             ] == "rwm"

      assert RuntimeSpec.normalize_device(%{"host_path" => "/dev/x", "permissions" => "RW"})[
               "permissions"
             ] == "rw"
    end
  end

  describe "validate_devices/2" do
    test "a relative host path is refused" do
      changeset = devices_changeset([%{"host_path" => "dev/net/tun"}])

      refute changeset.valid?
      assert [message] = errors(changeset)
      assert message =~ "absolute host path"
    end

    test "two devices cannot share a path inside the container" do
      # Docker takes one and drops the other, and which one decides whether the app
      # finds its hardware.
      changeset =
        devices_changeset([
          %{"host_path" => "/dev/ttyUSB0", "container_path" => "/dev/tty"},
          %{"host_path" => "/dev/ttyUSB1", "container_path" => "/dev/tty"}
        ])

      refute changeset.valid?
      assert [message] = errors(changeset)
      assert message =~ "cannot share a path"
    end

    test "junk permissions are reported even though normalize would have swallowed them" do
      # normalize_device/1 repairs so a bad form value can never lock an app out of its
      # device; validation reads the RAW value so the operator still hears about it.
      changeset = devices_changeset([%{"host_path" => "/dev/net/tun", "permissions" => "xyz"}])

      refute changeset.valid?
      assert [message] = errors(changeset)
      assert message =~ "r (read)"
    end

    test "a well-formed device passes" do
      assert devices_changeset([
               %{
                 "host_path" => "/dev/net/tun",
                 "container_path" => "/dev/net/tun",
                 "permissions" => "rwm"
               }
             ]).valid?
    end
  end

  describe "parse_sysctls/1" do
    test "accepts compose's list form as well as the map form" do
      assert RuntimeSpec.parse_sysctls(["net.core.somaxconn=1024"]) ==
               %{"net.core.somaxconn" => "1024"}

      assert RuntimeSpec.parse_sysctls(%{"net.core.somaxconn" => "1024"}) ==
               %{"net.core.somaxconn" => "1024"}
    end

    test "values are stringified — the Docker API rejects an integer" do
      assert RuntimeSpec.parse_sysctls(%{"net.core.somaxconn" => 1024}) ==
               %{"net.core.somaxconn" => "1024"}
    end
  end

  describe "validate_sysctls/2" do
    test "a sysctl outside a container's own namespace is refused" do
      # The daemon's message ("sysctl is not in a separate kernel namespace") reads as a
      # Docker bug rather than an invalid setting, so it is caught at save time instead.
      changeset = sysctls_changeset(%{"vm.max_map_count" => "262144"})

      refute changeset.valid?
      assert [message] = errors(changeset)
      assert message =~ "vm.max_map_count"
    end

    test "the namespaced families pass" do
      assert sysctls_changeset(%{"net.ipv4.conf.all.src_valid_mark" => "1"}).valid?
      assert sysctls_changeset(%{"fs.mqueue.queues_max" => "100"}).valid?
      assert sysctls_changeset(%{"kernel.shmmax" => "65536"}).valid?
    end
  end

  describe "privileged_capability?/1" do
    test "flags the ones that reach past the container, in either spelling" do
      assert RuntimeSpec.privileged_capability?("NET_ADMIN")
      assert RuntimeSpec.privileged_capability?("cap_sys_module")
      refute RuntimeSpec.privileged_capability?("NET_BIND_SERVICE")
      refute RuntimeSpec.privileged_capability?("CHOWN")
    end
  end
end
