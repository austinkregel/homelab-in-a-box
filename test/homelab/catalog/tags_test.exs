defmodule Homelab.Catalog.TagsTest do
  @moduledoc """
  Tag discovery. The behaviour that matters most here is the degradation: a tag list
  is a convenience on top of a free-text field, so every way a registry can fail must
  come back as an error tuple, never an exception.
  """
  # Not async: these swap the configured registry drivers via application env.
  use ExUnit.Case, async: false

  alias Homelab.Catalog.{Tags, TagInfo}

  defmodule HubStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:search, :list_tags]

    # Records the repo it was asked for, so a test can assert on normalization.
    def list_tags(repo, _opts) do
      send(self(), {:asked_for, repo})

      {:ok,
       [
         %TagInfo{tag: "1.24", last_updated: "2026-01-01T00:00:00Z"},
         %TagInfo{tag: "latest", last_updated: "2026-06-01T00:00:00Z"},
         %TagInfo{tag: "1.25", last_updated: "2026-03-01T00:00:00Z"}
       ]}
    end
  end

  defmodule NoTagsStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:search]
    def list_tags(_repo, _opts), do: {:ok, []}
  end

  defmodule ErroringStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:list_tags]
    def list_tags(_repo, _opts), do: {:error, {:http_error, 429}}
  end

  defmodule RaisingStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:list_tags]
    def list_tags(_repo, _opts), do: raise("registry exploded")
  end

  defmodule GarbageStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:list_tags]
    def list_tags(_repo, _opts), do: :not_a_tuple
  end

  defmodule UndatedStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:list_tags]

    def list_tags(_repo, _opts) do
      {:ok,
       [
         %TagInfo{tag: "undated", last_updated: nil},
         # 2027-01-15, comfortably later than the ISO entry below.
         %TagInfo{tag: "epoch", last_updated: 1_800_000_000},
         %TagInfo{tag: "iso", last_updated: "2026-06-01T00:00:00Z"},
         %TagInfo{tag: "blank", last_updated: "not a date"},
         %TagInfo{tag: nil, last_updated: "2026-07-01T00:00:00Z"}
       ]}
    end
  end

  setup do
    previous_registries = Application.get_env(:homelab, :registries)
    previous_domain = Application.get_env(:homelab, :base_domain)

    # Pins the self-hosted registry prefix so driver resolution never reads Settings.
    Application.put_env(:homelab, :base_domain, "test.local")

    on_exit(fn ->
      restore(:registries, previous_registries)
      restore(:base_domain, previous_domain)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, value), do: Application.put_env(:homelab, key, value)

  defp with_registries(mods), do: Application.put_env(:homelab, :registries, mods)

  describe "available_for/2" do
    test "returns the hosting driver's tags, newest first" do
      with_registries([HubStub])

      assert {:ok, tags} = Tags.available_for("nginx:1.24")
      assert Enum.map(tags, & &1.tag) == ["latest", "1.25", "1.24"]
    end

    test "asks Docker Hub for official images under library/" do
      # The normalization that decides whether the picker works at all for official
      # images. Without it the Hub tags endpoint 404s.
      with_registries([HubStub])

      assert {:ok, _tags} = Tags.available_for("nginx:1.24")
      assert_received {:asked_for, "library/nginx"}
    end

    test "asks for a namespaced image by its full path" do
      with_registries([HubStub])

      assert {:ok, _tags} = Tags.available_for("linuxserver/sonarr:latest")
      assert_received {:asked_for, "linuxserver/sonarr"}
    end

    test "honours a limit" do
      with_registries([HubStub])

      assert {:ok, [%{tag: "latest"}]} = Tags.available_for("nginx", limit: 1)
    end
  end

  describe "available_for/2 — unsupported, not failed" do
    test "a driver that does not advertise :list_tags is unsupported" do
      with_registries([NoTagsStub])

      assert {:error, :unsupported} = Tags.available_for("nginx:1.24")
    end

    test "a registry with no configured driver is unsupported" do
      with_registries([])

      assert {:error, :unsupported} = Tags.available_for("nginx:1.24")
    end

    test "a self-hosted ref is unsupported rather than sent to Docker Hub" do
      with_registries([HubStub])

      assert {:error, :unsupported} = Tags.available_for("registry.test.local/myapp:v1")
      refute_received {:asked_for, _repo}
    end

    test "a digest-pinned ref has no tag to move" do
      with_registries([HubStub])

      assert {:error, :unsupported} = Tags.available_for("nginx@sha256:abc123")
    end

    test "a malformed ref is unsupported rather than an exception" do
      with_registries([HubStub])

      assert {:error, :unsupported} = Tags.available_for("")
    end
  end

  describe "available_for/2 — degradation" do
    test "a driver error is returned, not raised" do
      with_registries([ErroringStub])

      assert {:error, {:http_error, 429}} = Tags.available_for("nginx:1.24")
    end

    test "a driver that raises is caught" do
      # A rate-limited or reshaped registry response must not take out the Settings
      # page the operator is on.
      with_registries([RaisingStub])

      assert {:error, {:exception, "registry exploded"}} = Tags.available_for("nginx:1.24")
    end

    test "a driver returning an unexpected shape is caught" do
      with_registries([GarbageStub])

      assert {:error, {:unexpected, :not_a_tuple}} = Tags.available_for("nginx:1.24")
    end
  end

  describe "available_for/2 — sorting mixed timestamp formats" do
    test "dated tags lead, undated tags survive at the end, untagged entries are dropped" do
      with_registries([UndatedStub])

      assert {:ok, tags} = Tags.available_for("nginx")
      names = Enum.map(tags, & &1.tag)

      # An epoch number and an ISO string sort against each other correctly.
      assert ["epoch", "iso" | rest] = names
      # Unparseable and absent dates keep the tag rather than dropping it.
      assert Enum.sort(rest) == ["blank", "undated"]
      # An entry with no tag at all is not a version anyone can pick.
      refute nil in names
    end
  end

  describe "supported?/1" do
    test "reports whether a picker can be offered before spending a request" do
      with_registries([HubStub])
      assert Tags.supported?("nginx:1.24")
      refute Tags.supported?("nginx@sha256:abc123")
      refute Tags.supported?("registry.test.local/myapp:v1")

      with_registries([NoTagsStub])
      refute Tags.supported?("nginx:1.24")
    end
  end
end
