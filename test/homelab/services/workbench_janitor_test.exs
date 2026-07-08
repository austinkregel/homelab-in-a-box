defmodule Homelab.Services.WorkbenchJanitorTest do
  # async: false — the janitor is a named singleton and this test mutates the
  # process-global :workbench app env.
  use ExUnit.Case, async: false

  alias Homelab.Services.WorkbenchJanitor
  alias Homelab.Workbench

  setup do
    root = Path.join(System.tmp_dir!(), "janitor-test-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:homelab, :workbench)

    # ttl_hours: 0 makes every existing workspace immediately stale.
    Application.put_env(:homelab, :workbench, root: root, quota_bytes: 1_000, ttl_hours: 0)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:homelab, :workbench, prev)
    end)

    {:ok, root: root, user_id: System.unique_integer([:positive])}
  end

  test "purges stale workspaces on its interval", %{user_id: uid} do
    src = Path.join(System.tmp_dir!(), "janitor-src-#{System.unique_integer([:positive])}")
    File.write!(src, "data")
    on_exit(fn -> File.rm(src) end)

    assert {:ok, _} = Workbench.add_file(uid, "f.txt", src)
    assert File.dir?(Workbench.workspace_dir(uid))

    # A short interval so the first scheduled purge fires almost immediately.
    {:ok, pid} = WorkbenchJanitor.start_link(interval: 10)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert eventually(fn -> not File.dir?(Workbench.workspace_dir(uid)) end)
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end
end
