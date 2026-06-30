defmodule Homelab.Schemas.SystemSettingChangesetTest do
  use Homelab.DataCase, async: true

  alias Homelab.Settings.SystemSetting

  defp changeset(attrs), do: SystemSetting.changeset(%SystemSetting{}, attrs)

  describe "changeset/2 required fields" do
    test "is valid with key and category" do
      assert changeset(%{key: "feature.x", category: "general"}).valid?
    end

    test "is valid with key, value, and category" do
      assert changeset(%{key: "feature.x", value: "on", category: "features"}).valid?
    end

    test "requires key (category has a schema default so it is pre-populated)" do
      cs = changeset(%{})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).key
      # category defaults to "general" on the struct, so validate_required passes
      refute Map.has_key?(errors_on(cs), :category)
    end

    test "flags category as blank when explicitly cast to nil" do
      cs = changeset(%{key: "k", category: nil})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).category
    end

    test "requires key when category present" do
      cs = changeset(%{category: "general"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).key
    end

    test "value is optional" do
      cs = changeset(%{key: "no.value", category: "general"})
      assert cs.valid?
    end
  end

  describe "changeset/2 optional fields and defaults" do
    test "casts encrypted and category" do
      cs = changeset(%{key: "secret.token", value: "abc", encrypted: true, category: "secrets"})
      assert cs.valid?
      assert get_change(cs, :encrypted) == true
      assert get_change(cs, :category) == "secrets"
    end

    test "defaults encrypted to false and category to general on insert" do
      {:ok, setting} =
        %SystemSetting{}
        |> SystemSetting.changeset(%{key: "defaults.test", category: "general"})
        |> Repo.insert()

      assert setting.encrypted == false
      assert setting.category == "general"
    end
  end

  describe "unique_constraint on key" do
    test "rejects a duplicate key" do
      {:ok, _} =
        %SystemSetting{}
        |> SystemSetting.changeset(%{key: "dup.key", value: "1", category: "general"})
        |> Repo.insert()

      {:error, cs} =
        %SystemSetting{}
        |> SystemSetting.changeset(%{key: "dup.key", value: "2", category: "general"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).key
    end

    test "allows distinct keys" do
      assert {:ok, _} =
               %SystemSetting{}
               |> SystemSetting.changeset(%{key: "key.a", category: "general"})
               |> Repo.insert()

      assert {:ok, _} =
               %SystemSetting{}
               |> SystemSetting.changeset(%{key: "key.b", category: "general"})
               |> Repo.insert()
    end
  end
end
