defmodule Homelab.Catalogs.OsBases do
  @moduledoc """
  A built-in catalog of base operating-system images (Debian, Ubuntu, Alpine,
  Fedora, Rocky, Arch, BusyBox) by version.

  Unlike the community application catalogs, this is not a "wall of apps" — it is
  the minimal starting point for building your own images in the Workbench. Every
  entry references a plain, pullable Docker Hub image.
  """

  @behaviour Homelab.Behaviours.ApplicationCatalog

  alias Homelab.Catalog.CatalogEntry

  @source "os_bases"

  # {display name, image ref, version label, one-line description}
  @images [
    {"Debian 12 (bookworm)", "debian:bookworm", "bookworm", "Debian stable base image"},
    {"Debian 13 (trixie)", "debian:trixie", "trixie", "Debian testing base image"},
    {"Ubuntu 22.04 LTS", "ubuntu:22.04", "22.04", "Ubuntu Jammy Jellyfish LTS base image"},
    {"Ubuntu 24.04 LTS", "ubuntu:24.04", "24.04", "Ubuntu Noble Numbat LTS base image"},
    {"Alpine 3.20", "alpine:3.20", "3.20", "Minimal Alpine Linux base image"},
    {"Alpine 3.21", "alpine:3.21", "3.21", "Minimal Alpine Linux base image"},
    {"Fedora 41", "fedora:41", "41", "Fedora base image"},
    {"Fedora 42", "fedora:42", "42", "Fedora base image"},
    {"Rocky Linux 9", "rockylinux:9", "9", "Enterprise Linux (RHEL-compatible) base image"},
    {"Arch Linux", "archlinux:latest", "latest", "Rolling-release Arch Linux base image"},
    {"BusyBox", "busybox:latest", "latest", "Tiny single-binary userland base image"}
  ]

  @impl true
  def driver_id, do: @source

  @impl true
  def display_name, do: "OS bases"

  @impl true
  def description, do: "Base operating-system images (Debian, Ubuntu, Alpine, Fedora, ...)"

  @impl true
  def browse(_opts \\ []), do: {:ok, entries()}

  @impl true
  def search(query, _opts \\ []) do
    q = String.downcase(query)

    results =
      Enum.filter(entries(), fn entry ->
        String.contains?(String.downcase(entry.name), q) or
          String.contains?(String.downcase(entry.description || ""), q)
      end)

    {:ok, results}
  end

  @impl true
  def app_details(name) do
    case Enum.find(entries(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp entries do
    Enum.map(@images, fn {name, ref, version, description} ->
      %CatalogEntry{
        name: name,
        description: description,
        source: @source,
        full_ref: ref,
        version: version,
        categories: ["operating-system"],
        official?: true
      }
    end)
  end
end
