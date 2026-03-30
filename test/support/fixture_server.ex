defmodule Homelab.TestFixtures.ApiServer do
  @moduledoc """
  Wraps Bypass with canned API responses for third-party services.

  Each function registers route handlers on a Bypass instance and returns
  the base URL for injecting into module config.
  """

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  def docker_hub(bypass, opts \\ []) do
    search_results = Keyword.get(opts, :search_results, [
      %{"repo_name" => "nginx", "repo_owner" => "library", "short_description" => "Nginx web server",
        "star_count" => 1000, "pull_count" => 500_000, "is_official" => true}
    ])

    tag_results = Keyword.get(opts, :tag_results, [
      %{"name" => "latest", "digest" => "sha256:abc123", "last_updated" => "2024-01-01T00:00:00Z",
        "full_size" => 50_000_000, "images" => [%{"architecture" => "amd64"}]}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      cond do
        String.contains?(conn.request_path, "/search/repositories") ->
          json_resp(conn, 200, %{"results" => search_results})

        String.contains?(conn.request_path, "/tags") ->
          json_resp(conn, 200, %{"results" => tag_results})

        true ->
          Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def ghcr(bypass, opts \\ []) do
    packages = Keyword.get(opts, :packages, [
      %{"name" => "myapp", "html_url" => "https://github.com/org/myapp"}
    ])

    versions = Keyword.get(opts, :versions, [
      %{"name" => "v1.0.0", "created_at" => "2024-01-01T00:00:00Z",
        "metadata" => %{"container" => %{"tags" => ["latest", "v1.0.0"]}}}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      cond do
        String.contains?(conn.request_path, "/packages/container/") and
          String.contains?(conn.request_path, "/versions") ->
          json_resp(conn, 200, versions)

        String.contains?(conn.request_path, "/packages") ->
          json_resp(conn, 200, packages)

        true ->
          Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def ecr(bypass, opts \\ []) do
    repos = Keyword.get(opts, :repositories, [
      %{"repositoryName" => "nginx", "repositoryDescription" => "Nginx image"}
    ])

    tags = Keyword.get(opts, :tags, [
      %{"imageTag" => "latest", "imageDigest" => "sha256:abc", "imagePushedAt" => 1704067200, "imageSizeInBytes" => 50_000_000}
    ])

    Bypass.stub(bypass, "POST", "/", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      target = Plug.Conn.get_req_header(conn, "x-amz-target") |> List.first("")

      response =
        cond do
          String.contains?(target, "DescribeRepositories") ->
            %{"repositories" => repos}

          String.contains?(target, "DescribeImageTags") ->
            %{"imageTagDetails" => tags}

          true ->
            %{"error" => "unknown target"}
        end

      json_resp(conn, 200, response)
    end)

    "http://localhost:#{bypass.port}"
  end

  def cloudflare_dns(bypass, opts \\ []) do
    records = Keyword.get(opts, :records, [
      %{"id" => "rec_1", "name" => "app.example.com", "type" => "A", "content" => "1.2.3.4", "ttl" => 300, "proxied" => false}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      cond do
        conn.method == "GET" and String.contains?(conn.request_path, "/dns_records") ->
          json_resp(conn, 200, %{
            "result" => records,
            "result_info" => %{"total_pages" => 1}
          })

        conn.method == "POST" and String.contains?(conn.request_path, "/dns_records") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          record = Jason.decode!(body)
          result = Map.merge(record, %{"id" => "rec_new_#{System.unique_integer([:positive])}"})
          json_resp(conn, 200, %{"result" => result})

        conn.method == "PUT" and String.contains?(conn.request_path, "/dns_records/") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          record = Jason.decode!(body)
          json_resp(conn, 200, %{"result" => record})

        conn.method == "DELETE" and String.contains?(conn.request_path, "/dns_records/") ->
          json_resp(conn, 200, %{})

        true ->
          Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def cloudflare_registrar(bypass, opts \\ []) do
    zones = Keyword.get(opts, :zones, [
      %{"name" => "example.com", "id" => "zone_1", "status" => "active", "name_servers" => ["ns1.cloudflare.com", "ns2.cloudflare.com"]}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      if conn.method == "GET" and String.contains?(conn.request_path, "/zones") do
        params = Plug.Conn.fetch_query_params(conn).query_params

        filtered =
          if name = params["name"] do
            Enum.filter(zones, &(&1["name"] == name))
          else
            zones
          end

        json_resp(conn, 200, %{
          "result" => filtered,
          "result_info" => %{"total_pages" => 1}
        })
      else
        Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def pihole(bypass, opts \\ []) do
    cname_records = Keyword.get(opts, :cname_records, [
      %{"domain" => "app.local", "target" => "server.local"}
    ])

    a_records = Keyword.get(opts, :a_records, [
      %{"domain" => "host.local", "ip" => "192.168.1.10"}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      cond do
        conn.method == "GET" and String.ends_with?(conn.request_path, "/cname") ->
          json_resp(conn, 200, %{"data" => cname_records})

        conn.method == "GET" and String.ends_with?(conn.request_path, "/a") ->
          json_resp(conn, 200, %{"data" => a_records})

        conn.method == "POST" ->
          json_resp(conn, 201, %{"status" => "ok"})

        conn.method == "DELETE" ->
          json_resp(conn, 200, %{})

        true ->
          Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def unifi(bypass, opts \\ []) do
    records = Keyword.get(opts, :records, [
      %{"_id" => "rec_1", "key" => "app.local", "record_type" => "A", "value" => "192.168.1.10", "ttl" => 300}
    ])

    Bypass.stub(bypass, :any, :any, fn conn ->
      cond do
        conn.method == "GET" and String.contains?(conn.request_path, "/dns/policies") ->
          json_resp(conn, 200, records)

        conn.method == "GET" and String.contains?(conn.request_path, "/static-dns") ->
          json_resp(conn, 200, records)

        conn.method == "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          record = Jason.decode!(body)
          result = Map.merge(record, %{"_id" => "rec_new"})
          json_resp(conn, 200, result)

        conn.method == "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          record = Jason.decode!(body)
          json_resp(conn, 200, record)

        conn.method == "DELETE" ->
          json_resp(conn, 200, %{})

        true ->
          Plug.Conn.resp(conn, 404, "Not Found")
      end
    end)

    "http://localhost:#{bypass.port}"
  end

  def traefik_metrics(bypass, opts \\ []) do
    metrics_text = Keyword.get(opts, :metrics, """
    traefik_service_requests_total{code="200",method="GET",protocol="http",service="myapp@docker"} 150
    traefik_service_requests_total{code="404",method="GET",protocol="http",service="myapp@docker"} 5
    traefik_service_requests_total{code="500",method="GET",protocol="http",service="myapp@docker"} 2
    traefik_service_requests_bytes_total{code="200",method="GET",protocol="http",service="myapp@docker"} 1024000
    traefik_service_responses_bytes_total{code="200",method="GET",protocol="http",service="myapp@docker"} 5120000
    """)

    Bypass.stub(bypass, "GET", "/metrics", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(200, metrics_text)
    end)

    "http://localhost:#{bypass.port}"
  end
end
