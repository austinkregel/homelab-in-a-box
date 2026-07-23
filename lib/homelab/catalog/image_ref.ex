defmodule Homelab.Catalog.ImageRef do
  @moduledoc """
  Parsing and rebuilding of container image references.

  Every surface that touched an image ref used to do its own string work, and each
  got a different subset right: the catalog quick-deploy joined `image` and `tag` with
  `String.contains?(image, ":")` (which mistakes a registry PORT for a tag —
  `registry.example.com:5000/app` "already has a tag"), the wizard passed the ref
  through raw, and the registry drivers each expected a different shape.

  The grammar, per Docker's own reference spec:

      [registry[:port]/]path[:tag][@digest]

  The two things that make naive splitting wrong:

    * **A colon does not imply a tag.** `host:5000/app` is a registry port. A tag can
      only appear after the last `/`.
    * **A slash does not imply a registry.** `linuxserver/sonarr` is a Docker Hub
      namespace, not a host. Docker's rule: the first component is a registry only if
      it contains a `.` or a `:`, or is exactly `localhost`.

  A digest pins content and outranks a tag, so a ref carrying one is left alone by
  `with_tag/2` — silently appending `:v2` to a `@sha256:` ref would produce something
  the daemon accepts and then ignores.
  """

  @default_registry "docker.io"

  @type t :: %{
          registry: String.t() | nil,
          path: String.t(),
          tag: String.t() | nil,
          digest: String.t() | nil
        }

  @doc """
  Splits a reference into its parts. `registry` is `nil` for an implicit Docker Hub
  ref; `tag` is `nil` when none was written (which Docker resolves as `latest`, but
  we do not invent it here — "unspecified" and "explicitly latest" are different
  things to an operator choosing a version).
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid}
  def parse(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    if trimmed == "" or String.match?(trimmed, ~r/\s/) do
      {:error, :invalid}
    else
      {remainder, digest} = split_digest(trimmed)
      {registry, rest} = split_registry(remainder)
      {path, tag} = split_tag(rest)

      if path == "" do
        {:error, :invalid}
      else
        {:ok, %{registry: registry, path: path, tag: tag, digest: digest}}
      end
    end
  end

  def parse(_ref), do: {:error, :invalid}

  @doc "Rebuilds a reference from its parts."
  @spec to_string(t()) :: String.t()
  def to_string(%{registry: registry, path: path, tag: tag, digest: digest}) do
    [registry, path]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("/")
    |> then(fn base -> if tag, do: base <> ":" <> tag, else: base end)
    |> then(fn base -> if digest, do: base <> "@" <> digest, else: base end)
  end

  @doc """
  Replaces the tag on a reference, preserving the registry and path.

  A digest-pinned ref is returned unchanged: the digest already decides the content,
  so a tag alongside it is decoration the daemon ignores.
  """
  @spec with_tag(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def with_tag(ref, tag) when is_binary(tag) do
    with {:ok, parsed} <- parse(ref) do
      if parsed.digest do
        {:ok, __MODULE__.to_string(parsed)}
      else
        {:ok, __MODULE__.to_string(%{parsed | tag: tag})}
      end
    end
  end

  @doc "The tag written on a reference, or `nil` when it carries none."
  @spec tag(String.t()) :: String.t() | nil
  def tag(ref) do
    case parse(ref) do
      {:ok, %{tag: tag}} -> tag
      {:error, :invalid} -> nil
    end
  end

  @doc """
  The repository string a registry driver's `list_tags/2` expects.

  Docker Hub's API namespaces official images under `library/`, so a bare `nginx`
  must be sent as `library/nginx` — without it the tags endpoint 404s, which is why
  a naive version picker appears to work for `linuxserver/sonarr` and silently fails
  for every official image.

  Returns `{:error, :invalid}` for a ref we cannot address, including digest-pinned
  refs: those have no tag to list against.
  """
  @spec registry_repo(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def registry_repo(ref) do
    with {:ok, parsed} <- parse(ref) do
      cond do
        parsed.digest -> {:error, :invalid}
        docker_hub?(parsed.registry) -> {:ok, hub_repo(parsed.path)}
        true -> {:ok, parsed.path}
      end
    end
  end

  @doc "True when the reference names Docker Hub, explicitly or by omission."
  @spec docker_hub?(String.t() | nil) :: boolean()
  def docker_hub?(nil), do: true

  def docker_hub?(registry),
    do: registry in [@default_registry, "index.docker.io", "registry-1.docker.io"]

  # --- Private ---

  defp split_digest(ref) do
    case String.split(ref, "@", parts: 2) do
      [remainder, digest] when digest != "" -> {remainder, digest}
      _ -> {ref, nil}
    end
  end

  # The first component is a REGISTRY only if it looks like a host: it contains a dot
  # (a domain), a colon (a port), or is literally `localhost`. Otherwise it is a Docker
  # Hub namespace -- `linuxserver/sonarr` has no registry, `lscr.io/linuxserver/sonarr`
  # does. Getting this backwards sends `linuxserver` to the driver as a hostname.
  defp split_registry(ref) do
    case String.split(ref, "/", parts: 2) do
      [first, rest] ->
        if String.contains?(first, ".") or String.contains?(first, ":") or first == "localhost" do
          {first, rest}
        else
          {nil, ref}
        end

      _ ->
        {nil, ref}
    end
  end

  # A tag can only follow the LAST slash. `host:5000/app` has a port, not a tag; this
  # is the split that `String.contains?(image, ":")` gets wrong.
  defp split_tag(rest) do
    case String.split(rest, ":", parts: 2) do
      [path, tag] when tag != "" -> {path, tag}
      _ -> {rest, nil}
    end
  end

  # Docker Hub's API addresses official (single-component) images under `library/`.
  defp hub_repo(path) do
    if String.contains?(path, "/"), do: path, else: "library/" <> path
  end
end
