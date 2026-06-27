defmodule Homelab.Schemas.NotificationChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Notifications.Notification

  @valid_attrs %{title: "Hello", severity: "info"}

  defp changeset(attrs), do: Notification.changeset(%Notification{}, attrs)

  describe "changeset/2 required fields" do
    test "is valid with title and severity" do
      assert changeset(@valid_attrs).valid?
    end

    test "requires title (severity is pre-populated by its schema default)" do
      cs = changeset(%{})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).title
      # severity defaults to "info" on the struct, so validate_required is satisfied
      refute Map.has_key?(errors_on(cs), :severity)
    end

    test "flags severity as blank when explicitly cast to nil" do
      cs = changeset(%{title: "t", severity: nil})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).severity
    end

    test "requires title when severity present" do
      cs = changeset(%{severity: "info"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).title
    end
  end

  describe "changeset/2 severity inclusion" do
    test "accepts each allowed severity" do
      for sev <- ["info", "warning", "error", "success"] do
        assert changeset(%{title: "t", severity: sev}).valid?
      end
    end

    test "rejects an unknown severity" do
      cs = changeset(%{title: "t", severity: "critical"})
      refute cs.valid?
      assert "is invalid" in errors_on(cs).severity
    end

    test "empty-string severity is cast to nil and falls back to the schema default" do
      # Ecto treats "" as an empty value, so the change is dropped and the
      # struct default "info" remains -> the changeset stays valid.
      cs = changeset(%{title: "t", severity: ""})
      assert cs.valid?
    end
  end

  describe "changeset/2 optional fields" do
    test "casts body, link, read_at, and user_id" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      cs =
        changeset(%{
          title: "t",
          severity: "info",
          body: "details",
          link: "/path",
          read_at: now
        })

      assert cs.valid?
      assert get_change(cs, :body) == "details"
      assert get_change(cs, :link) == "/path"
      assert get_change(cs, :read_at) == now
    end
  end

  describe "foreign_key_constraint on user_id" do
    test "rejects a non-existent user_id" do
      {:error, cs} =
        %Notification{}
        |> Notification.changeset(%{title: "t", severity: "info", user_id: -1})
        |> Repo.insert()

      assert "does not exist" in errors_on(cs).user_id
    end

    test "inserts with a valid user_id" do
      user = insert(:user)

      assert {:ok, _} =
               %Notification{}
               |> Notification.changeset(%{title: "t", severity: "info", user_id: user.id})
               |> Repo.insert()
    end

    test "inserts with nil user_id (system-wide notification)" do
      assert {:ok, n} =
               %Notification{}
               |> Notification.changeset(%{title: "t", severity: "info"})
               |> Repo.insert()

      assert n.user_id == nil
    end
  end
end
