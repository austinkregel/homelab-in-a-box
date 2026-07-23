defmodule Homelab.Catalog.ImageRefTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.ImageRef

  describe "parse/1 — registry vs namespace" do
    test "a bare official image has no registry and no tag" do
      assert {:ok, %{registry: nil, path: "nginx", tag: nil, digest: nil}} =
               ImageRef.parse("nginx")
    end

    test "a slash alone does not make the first component a registry" do
      # `linuxserver` is a Docker Hub namespace. Treating it as a host is what sends
      # a driver looking for tags at http://linuxserver/.
      assert {:ok, %{registry: nil, path: "linuxserver/sonarr"}} =
               ImageRef.parse("linuxserver/sonarr")
    end

    test "a dotted first component is a registry" do
      assert {:ok, %{registry: "ghcr.io", path: "hotio/sonarr", tag: "latest"}} =
               ImageRef.parse("ghcr.io/hotio/sonarr:latest")
    end

    test "localhost is a registry despite having no dot" do
      assert {:ok, %{registry: "localhost", path: "app", tag: "dev"}} =
               ImageRef.parse("localhost/app:dev")
    end
  end

  describe "parse/1 — the colon that is not a tag" do
    test "a registry port is not mistaken for a tag" do
      assert {:ok, %{registry: "registry.example.com:5000", path: "app", tag: nil}} =
               ImageRef.parse("registry.example.com:5000/app")
    end

    test "a registry port and a tag coexist" do
      assert {:ok, %{registry: "registry.example.com:5000", path: "app", tag: "v2"}} =
               ImageRef.parse("registry.example.com:5000/app:v2")
    end
  end

  describe "parse/1 — digests" do
    test "a digest is split out and the tag stays nil" do
      assert {:ok, %{path: "nginx", tag: nil, digest: "sha256:abc123"}} =
               ImageRef.parse("nginx@sha256:abc123")
    end

    test "a tag and a digest can both be present" do
      assert {:ok, %{path: "nginx", tag: "1.25", digest: "sha256:abc123"}} =
               ImageRef.parse("nginx:1.25@sha256:abc123")
    end
  end

  describe "parse/1 — rejections" do
    test "blank and whitespace-bearing refs are invalid" do
      assert {:error, :invalid} = ImageRef.parse("")
      assert {:error, :invalid} = ImageRef.parse("   ")
      assert {:error, :invalid} = ImageRef.parse("nginx latest")
    end

    test "a ref with no name component is invalid" do
      assert {:error, :invalid} = ImageRef.parse("ghcr.io/")
    end

    test "a non-binary is invalid rather than raising" do
      assert {:error, :invalid} = ImageRef.parse(nil)
    end
  end

  describe "to_string/1 round-trips" do
    for ref <- [
          "nginx",
          "nginx:1.25",
          "linuxserver/sonarr:latest",
          "ghcr.io/hotio/sonarr:release",
          "registry.example.com:5000/app:v2",
          "nginx@sha256:abc123",
          "nginx:1.25@sha256:abc123"
        ] do
      test "#{ref}" do
        ref = unquote(ref)
        assert {:ok, parsed} = ImageRef.parse(ref)
        assert ImageRef.to_string(parsed) == ref
      end
    end
  end

  describe "with_tag/2" do
    test "replaces an existing tag" do
      assert {:ok, "nginx:1.25"} = ImageRef.with_tag("nginx:1.24", "1.25")
    end

    test "adds a tag to a ref that had none" do
      assert {:ok, "nginx:1.25"} = ImageRef.with_tag("nginx", "1.25")
    end

    test "preserves the registry and a port" do
      assert {:ok, "registry.example.com:5000/app:v3"} =
               ImageRef.with_tag("registry.example.com:5000/app:v2", "v3")
    end

    test "leaves a digest-pinned ref alone" do
      # The digest already decides the content; appending a tag would produce
      # something the daemon accepts and then ignores.
      assert {:ok, "nginx@sha256:abc123"} = ImageRef.with_tag("nginx@sha256:abc123", "1.25")
    end

    test "an invalid ref does not become a valid one" do
      assert {:error, :invalid} = ImageRef.with_tag("", "1.25")
    end
  end

  describe "tag/1" do
    test "returns the written tag, or nil when none was written" do
      assert ImageRef.tag("nginx:1.25") == "1.25"
      assert ImageRef.tag("nginx") == nil
      assert ImageRef.tag("registry.example.com:5000/app") == nil
    end
  end

  describe "registry_repo/1" do
    test "official Docker Hub images are addressed under library/" do
      # Without this the Hub tags endpoint 404s, so a version picker appears to work
      # for namespaced images and silently fails for every official one.
      assert {:ok, "library/nginx"} = ImageRef.registry_repo("nginx")
      assert {:ok, "library/nginx"} = ImageRef.registry_repo("nginx:1.25")
    end

    test "a namespaced Docker Hub image is passed through" do
      assert {:ok, "linuxserver/sonarr"} = ImageRef.registry_repo("linuxserver/sonarr:latest")
    end

    test "an explicit docker.io host still resolves to the Hub shape" do
      assert {:ok, "library/nginx"} = ImageRef.registry_repo("docker.io/nginx")
    end

    test "a non-Hub registry keeps its path and drops the host" do
      assert {:ok, "hotio/sonarr"} = ImageRef.registry_repo("ghcr.io/hotio/sonarr:release")
    end

    test "a digest-pinned ref has no tags to list" do
      assert {:error, :invalid} = ImageRef.registry_repo("nginx@sha256:abc123")
    end
  end

  describe "docker_hub?/1" do
    test "recognizes the Hub's aliases and an absent registry" do
      assert ImageRef.docker_hub?(nil)
      assert ImageRef.docker_hub?("docker.io")
      assert ImageRef.docker_hub?("index.docker.io")
      refute ImageRef.docker_hub?("ghcr.io")
    end
  end
end
