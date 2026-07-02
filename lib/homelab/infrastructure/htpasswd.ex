defmodule Homelab.Infrastructure.Htpasswd do
  @moduledoc """
  Generates a bcrypt htpasswd line for the self-hosted registry's auth file.

  The Docker registry requires bcrypt htpasswd entries. Rather than pull in a
  compiled bcrypt NIF dependency for a single line of output, this runs the
  `htpasswd` tool from a throwaway `httpd:2` container over the Docker API
  (`htpasswd -Bbn <user> <pass>` → `user:$2y$...` on stdout) and force-removes it.

  Tradeoff: the password is briefly present on the ephemeral container's argv
  (visible via `docker inspect` for its sub-second lifetime). Acceptable for a
  single-tenant self-hosted admin tool.
  """

  require Logger
  alias Homelab.Docker.Client

  @image "httpd:2"

  @doc """
  Returns `{:ok, "user:$2y$..."}` — a single bcrypt htpasswd line — or `{:error, reason}`.
  """
  def generate(user, pass) when is_binary(user) and is_binary(pass) do
    _ = Client.post_stream("/images/create?fromImage=#{URI.encode(@image)}")

    body = %{
      "Image" => @image,
      "Cmd" => ["htpasswd", "-Bbn", user, pass],
      "HostConfig" => %{"NetworkMode" => "none", "AutoRemove" => false}
    }

    with {:ok, %{"Id" => id}} <- Client.post("/containers/create", body),
         {:ok, _} <- Client.post("/containers/#{id}/start"),
         {:ok, _} <- Client.post("/containers/#{id}/wait"),
         {:ok, logs} <- Client.get("/containers/#{id}/logs?stdout=true&stderr=false") do
      _ = Client.delete("/containers/#{id}?force=true")
      line = logs |> strip_docker_log_headers() |> String.trim()

      if String.contains?(line, ":$2") do
        {:ok, line}
      else
        {:error, {:htpasswd_failed, line}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Docker multiplexed log output frames each chunk with an 8-byte header
  # (stream byte, 3 reserved, 4-byte big-endian length). Strip them to recover
  # the raw payload.
  defp strip_docker_log_headers(binary) when is_binary(binary) do
    strip_frames(binary, [])
  end

  defp strip_frames(<<_stream, 0, 0, 0, size::32, rest::binary>>, acc)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remainder::binary>> = rest
    strip_frames(remainder, [payload | acc])
  end

  defp strip_frames(remainder, acc) do
    # Either no more full frames, or output was never multiplexed (no TTY) —
    # append whatever is left verbatim.
    (Enum.reverse(acc) ++ [remainder]) |> IO.iodata_to_binary()
  end
end
