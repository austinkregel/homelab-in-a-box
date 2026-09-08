defmodule Homelab.Deployments.UnusedMarkerTest do
  @moduledoc """
  Every row parser, against the payload LiveView actually posts.

  `Homelab.IndexedParamsTest` covers the helper; this covers the parsers THROUGH their
  own public functions, so a parser that stops using the helper is caught here rather
  than in production. The marker is the whole payload under test: a form section the
  operator has not typed into yet posts `_unused_0` beside row `0`, and each of these
  parsers used to raise on it and take the LiveView down.
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.{ConfigForm, RuntimeSpec, VolumeSpec}

  test "the volumes editor survives a marker" do
    params = %{"_unused_0" => "", "0" => %{"container_path" => "/data", "kind" => "managed"}}

    assert [%{"container_path" => "/data"}] = VolumeSpec.parse_rows(params)
  end

  test "the volumes editor keeps row order under markers" do
    params = %{
      "_unused_0" => "",
      "1" => %{"container_path" => "/second", "kind" => "managed"},
      "0" => %{"container_path" => "/first", "kind" => "managed"}
    }

    assert [%{"container_path" => "/first"}, %{"container_path" => "/second"}] =
             VolumeSpec.parse_rows(params)
  end

  test "the ports editor survives a marker" do
    params = %{"_unused_0" => "", "0" => %{"internal" => "5432", "protocol" => "tcp"}}

    assert [%{"internal" => "5432"}] = ConfigForm.parse_ports(params)
  end

  test "the devices editor survives a marker" do
    params = %{"_unused_0" => "", "0" => %{"host_path" => "/dev/dri", "permissions" => "rwm"}}

    assert [%{"host_path" => "/dev/dri"}] = RuntimeSpec.parse_device_rows(params)
  end
end
