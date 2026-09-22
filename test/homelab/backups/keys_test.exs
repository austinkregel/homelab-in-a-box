defmodule Homelab.Backups.KeysTest do
  use Homelab.DataCase, async: false

  alias Homelab.Backups.Keys

  setup do
    dir = Path.join(System.tmp_dir!(), "hiab-keys-#{System.unique_integer([:positive])}")
    prev = System.get_env("HOMELAB_SECRETS_DIR")
    System.put_env("HOMELAB_SECRETS_DIR", dir)

    on_exit(fn ->
      if prev,
        do: System.put_env("HOMELAB_SECRETS_DIR", prev),
        else: System.delete_env("HOMELAB_SECRETS_DIR")

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  describe "ensure!/0" do
    test "generates a key on first call and returns the same one after", %{dir: dir} do
      key = Keys.ensure!()

      assert byte_size(key) == 32
      assert File.exists?(Path.join(dir, "recovery_key"))
      assert Keys.ensure!() == key
    end

    test "persists the key in the form the operator is shown", %{dir: dir} do
      key = Keys.ensure!()

      assert File.read!(Path.join(dir, "recovery_key")) == Keys.format(key)
    end

    test "stores the key readable only by its owner", %{dir: dir} do
      Keys.ensure!()

      %File.Stat{mode: mode} = File.stat!(Path.join(dir, "recovery_key"))
      assert Bitwise.band(mode, 0o077) == 0
    end

    # An unpersisted key encrypts backups that are unreadable after the next restart,
    # so this refuses rather than handing back a key it could not save.
    test "raises when the key cannot be persisted" do
      blocked = Path.join(System.tmp_dir!(), "hiab-blocked-#{System.unique_integer([:positive])}")
      File.write!(blocked, "")
      System.put_env("HOMELAB_SECRETS_DIR", Path.join(blocked, "nested"))
      on_exit(fn -> File.rm_rf(blocked) end)

      assert_raise RuntimeError, ~r/Could not persist the backup Recovery Key/, fn ->
        Keys.ensure!()
      end
    end
  end

  describe "read/0" do
    test "reports absent before a key is provisioned" do
      assert Keys.read() == {:error, :absent}
      refute Keys.provisioned?()
    end

    test "returns the provisioned key" do
      key = Keys.ensure!()

      assert Keys.read() == {:ok, key}
      assert Keys.provisioned?()
    end
  end

  describe "format/1 and parse/1" do
    test "round-trips" do
      key = :crypto.strong_rand_bytes(32)

      assert {:ok, ^key} = key |> Keys.format() |> Keys.parse()
    end

    test "formats as dash-separated groups of four" do
      formatted = Keys.format(:crypto.strong_rand_bytes(32))

      assert Regex.match?(~r/^([A-Z2-7]{4}-)*[A-Z2-7]{1,4}$/, formatted)
    end

    # Base32 has no 0/O or 1/I, so a transcribed key cannot be ambiguous.
    test "uses an alphabet without ambiguous characters" do
      formatted = Keys.format(:crypto.strong_rand_bytes(32))

      refute String.contains?(formatted, ["0", "1", "8", "9"])
    end

    test "accepts a key typed back in any case, with any separators" do
      key = :crypto.strong_rand_bytes(32)
      typed = key |> Keys.format() |> String.downcase() |> String.replace("-", " ")

      assert {:ok, ^key} = Keys.parse(typed)
    end

    test "rejects a single mistyped character as a checksum failure" do
      formatted = Keys.format(:crypto.strong_rand_bytes(32))
      <<first::binary-1, second::binary-1, rest::binary>> = formatted
      swapped = if second == "A", do: "B", else: "A"

      assert Keys.parse(first <> swapped <> rest) == {:error, :checksum}
    end

    test "rejects input that is not a key at all" do
      assert Keys.parse("nonsense") == {:error, :malformed}
      assert Keys.parse("") == {:error, :malformed}
      assert Keys.parse(nil) == {:error, :malformed}
    end
  end

  describe "derived subkeys" do
    test "the bundle key and the backup master key differ" do
      Keys.ensure!()

      assert Keys.bundle_key() != Keys.backup_master_key()
    end

    test "both are 32 bytes and stable across calls" do
      Keys.ensure!()

      assert byte_size(Keys.bundle_key()) == 32
      assert byte_size(Keys.backup_master_key()) == 32
      assert Keys.bundle_key() == Keys.bundle_key()
    end

    test "a different recovery key derives different subkeys", %{dir: dir} do
      first = Keys.bundle_key()

      File.rm!(Path.join(dir, "recovery_key"))
      second = Keys.bundle_key()

      assert first != second
    end
  end

  describe "fingerprint/0" do
    test "identifies a key without disclosing it" do
      key = :crypto.strong_rand_bytes(32)
      fingerprint = Keys.fingerprint_of(key)

      assert Regex.match?(~r/^[0-9a-f]{16}$/, fingerprint)
      refute String.contains?(Keys.format(key), String.upcase(fingerprint))
    end

    test "differs between keys and is stable for one key" do
      a = :crypto.strong_rand_bytes(32)
      b = :crypto.strong_rand_bytes(32)

      assert Keys.fingerprint_of(a) == Keys.fingerprint_of(a)
      assert Keys.fingerprint_of(a) != Keys.fingerprint_of(b)
    end
  end

  describe "escrow" do
    test "is not escrowed until the operator confirms" do
      refute Keys.escrowed?()

      assert :ok = Keys.mark_escrowed()
      assert Keys.escrowed?()
    end
  end
end
