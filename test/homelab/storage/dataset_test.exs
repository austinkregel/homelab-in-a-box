defmodule Homelab.Storage.DatasetTest do
  use ExUnit.Case, async: true

  alias Homelab.Storage.Dataset

  test "sanitize_segment normalizes unsafe characters" do
    assert Dataset.sanitize_segment("GitLab CE!") == "gitlab_ce"
  end

  test "sanitize_segment truncates long slugs" do
    long = String.duplicate("a", 80)
    assert byte_size(Dataset.sanitize_segment(long)) <= 56
  end

  test "path rejects overly long full paths" do
    segments = for _ <- 1..20, do: String.duplicate("x", 20)
    assert {:error, :path_too_long} = Dataset.path("tank", segments)
  end

  test "path builds valid dataset path" do
    assert {:ok, "tank/appdata/dev/my-app"} = Dataset.path("tank", ["appdata", "dev", "my-app"])
  end
end
