defmodule Homelab.Docker.Image do
  @moduledoc """
  Image presence in the daemon's local store.

  Exists for one reason: **not every image has a registry to be pulled from.** An
  adopted container is, by definition, already running its image — and for any stack
  that builds its own (a Laravel Sail app, a compose `build:` stanza, anything from
  the Workbench), that image exists ONLY in the local store. Pulling it fails with an
  auth or not-found error from a registry that never had it, and the cutover rolls
  back on an image the daemon was holding the whole time.

  The `homelab-built/` prefix used to be the only exception, which covered our own
  builds and nothing else.
  """

  alias Homelab.Docker.Client

  @doc """
  True when the daemon already holds this image locally.

  Docker resolves the same defaults here as it does on `run` (a bare `foo` means
  `foo:latest`), so the reference is passed through as the operator wrote it.
  """
  def present?(image) when is_binary(image) do
    case Client.get("/images/#{URI.encode(image, &URI.char_unreserved?/1)}/json") do
      {:ok, body} when is_map(body) -> true
      _ -> false
    end
  end

  def present?(_image), do: false
end
