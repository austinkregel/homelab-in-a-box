defmodule Homelab.Networking.TlsProbeStarttlsTest do
  @moduledoc """
  The Postgres STARTTLS negotiation the probe performs before handshaking.

  A plain `:ssl.connect/4` against a Traefik TCP route would probably succeed, because
  Traefik falls through to normal TLS when the first bytes are not an SSLRequest. That
  makes it the wrong probe: it would report a healthy route for a configuration no
  `libpq` client can actually get through. These tests drive a local listener rather than
  the internet, so unlike the rest of `TlsProbeTest` they are not tagged `:integration`.
  """
  use ExUnit.Case, async: true

  alias Homelab.Networking.TlsProbe

  # What libpq sends: a 4-byte length of 8, then the SSLRequest request code.
  @ssl_request <<8::32, 80_877_103::32>>

  # Accepts one connection, hands the first 8 bytes back to the test, and replies with
  # `reply`. Returns the port it is listening on.
  defp listener(reply) do
    test_pid = self()

    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        packet: :raw,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(socket)

    spawn_link(fn ->
      {:ok, conn} = :gen_tcp.accept(socket)
      {:ok, received} = :gen_tcp.recv(conn, 8, 1_000)
      send(test_pid, {:received, received})
      if reply, do: :gen_tcp.send(conn, reply)
      # Held open so the probe's next read is the reply rather than a closed socket.
      Process.sleep(200)
      :gen_tcp.close(conn)
      :gen_tcp.close(socket)
    end)

    port
  end

  test "sends the SSLRequest libpq sends" do
    port = listener("N")

    TlsProbe.inspect_domain("localhost", port: port, starttls: :postgres, timeout: 1_000)

    assert_receive {:received, @ssl_request}, 1_000
  end

  # `N` is a well-formed refusal: the server understood the request and does not offer
  # TLS. Distinguished from a socket error because it means the route IS reaching
  # something that speaks Postgres.
  test "an explicit refusal is reported as such" do
    port = listener("N")

    assert {:error, {:handshake_failed, :starttls_refused}} =
             TlsProbe.inspect_domain("localhost", port: port, starttls: :postgres, timeout: 1_000)
  end

  # What an HTTP router answers with, which is exactly what a TCP route pointed at the
  # wrong entrypoint would produce.
  test "an HTTP response is reported as not-Postgres" do
    port = listener("H")

    assert {:error, {:handshake_failed, :not_postgres}} =
             TlsProbe.inspect_domain("localhost", port: port, starttls: :postgres, timeout: 1_000)
  end

  test "nothing listening is a connection error, not a crash" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:error, {:handshake_failed, _reason}} =
             TlsProbe.inspect_domain("localhost", port: port, starttls: :postgres, timeout: 1_000)
  end
end
