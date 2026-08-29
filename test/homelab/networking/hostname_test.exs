defmodule Homelab.Networking.HostnameTest do
  use ExUnit.Case, async: true

  alias Homelab.Networking.Hostname

  describe "normalize/1" do
    test "leaves a canonical hostname untouched" do
      assert Hostname.normalize("matrix.example.com") == "matrix.example.com"
    end

    test "trims, downcases and drops a trailing root dot" do
      assert Hostname.normalize("  Matrix.Example.COM.  ") == "matrix.example.com"
    end

    test "strips what a browser paste carries" do
      assert Hostname.normalize("https://matrix.example.com/") == "matrix.example.com"
      assert Hostname.normalize("http://example.com/some/path") == "example.com"
      assert Hostname.normalize("example.com:8443") == "example.com"
    end

    test "collapses an empty or non-binary value to nil" do
      assert Hostname.normalize("") == nil
      assert Hostname.normalize("   ") == nil
      assert Hostname.normalize(nil) == nil
      assert Hostname.normalize(123) == nil
    end

    test "does NOT split a multi-host value" do
      # Splitting changes how many things there are, so only `split/1` may do it --
      # otherwise a caller that can store one host would silently keep only the first.
      assert Hostname.normalize("a.example.com,b.example.com") == "a.example.com,b.example.com"
    end
  end

  describe "valid?/1" do
    test "accepts ordinary hostnames" do
      assert Hostname.valid?("example.com")
      assert Hostname.valid?("matrix.communication.ventures")
      assert Hostname.valid?("a-b.example.co.uk")
      assert Hostname.valid?("x1.example.com")
    end

    test "accepts a value that only needs normalizing" do
      assert Hostname.valid?("  Matrix.Example.COM. ")
      assert Hostname.valid?("https://example.com/path")
    end

    test "rejects the comma-joined value that broke the Traefik router" do
      refute Hostname.valid?("communication.ventures,matrix.communication.ventures")
    end

    test "rejects other multi-host separators" do
      refute Hostname.valid?("a.example.com b.example.com")
      refute Hostname.valid?("a.example.com;b.example.com")
    end

    test "requires at least two labels" do
      # A single label can never carry a public certificate, and requiring the dot is
      # what catches an app name or a path typed into a domain field.
      refute Hostname.valid?("localhost")
      refute Hostname.valid?("synapse")
    end

    test "rejects malformed labels" do
      refute Hostname.valid?("example..com")
      refute Hostname.valid?("-example.com")
      refute Hostname.valid?("example-.com")
      refute Hostname.valid?(".example.com")
      refute Hostname.valid?("exa_mple.com")
      refute Hostname.valid?("exa mple.com")
    end

    test "rejects blank and non-binary values" do
      refute Hostname.valid?("")
      refute Hostname.valid?(nil)
      refute Hostname.valid?(%{})
    end

    test "enforces the length limits" do
      long_label = String.duplicate("a", 64)
      refute Hostname.valid?("#{long_label}.example.com")
      assert Hostname.valid?("#{String.duplicate("a", 63)}.example.com")

      too_long = Enum.map_join(1..40, ".", fn _ -> String.duplicate("a", 6) end)
      refute Hostname.valid?(too_long)
    end
  end

  describe "split/1" do
    test "a single hostname yields a one-element list" do
      assert Hostname.split("example.com") == ["example.com"]
    end

    test "splits the value that started this" do
      assert Hostname.split("communication.ventures,matrix.communication.ventures") ==
               ["communication.ventures", "matrix.communication.ventures"]
    end

    test "accepts commas, spaces, semicolons and newlines, in any combination" do
      assert Hostname.split("a.example.com, b.example.com;c.example.com\nd.example.com") ==
               ["a.example.com", "b.example.com", "c.example.com", "d.example.com"]
    end

    test "normalizes each entry and drops blanks" do
      assert Hostname.split(" A.Example.com , , https://b.example.com/ ") ==
               ["a.example.com", "b.example.com"]
    end

    test "collapses duplicates, keeping first-seen order" do
      assert Hostname.split("b.example.com,a.example.com,b.example.com") ==
               ["b.example.com", "a.example.com"]
    end

    test "keeps invalid entries so a changeset can name what was typed" do
      # Silently dropping them would empty the field with no explanation.
      assert Hostname.split("example.com,not_a_host") == ["example.com", "not_a_host"]
    end

    test "returns [] for empty and non-binary values" do
      assert Hostname.split("") == []
      assert Hostname.split("  ,  ") == []
      assert Hostname.split(nil) == []
    end
  end

  describe "multi_host?/1" do
    test "true for several genuine hostnames" do
      assert Hostname.multi_host?("communication.ventures,matrix.communication.ventures")
      assert Hostname.multi_host?("a.example.com b.example.com c.example.com")
    end

    test "false for a single hostname" do
      refute Hostname.multi_host?("example.com")
    end

    test "false for typed prose, however many pieces it splits into" do
      # This is the whole point of the predicate: `split/1` breaks on whitespace, so any
      # sentence yields several pieces. "Contains a separator" is not "is a list".
      refute Hostname.multi_host?("not a host!")
      refute Hostname.multi_host?("my app domain")
    end

    test "false when only SOME pieces are hostnames" do
      refute Hostname.multi_host?("example.com, not_a_host")
    end

    test "false for blank and non-binary values" do
      refute Hostname.multi_host?("")
      refute Hostname.multi_host?(nil)
    end
  end

  describe "split_primary/1" do
    test "the first host is the primary, the rest are aliases" do
      assert Hostname.split_primary("communication.ventures,matrix.communication.ventures") ==
               {"communication.ventures", ["matrix.communication.ventures"]}
    end

    test "a single host has no aliases" do
      assert Hostname.split_primary("example.com") == {"example.com", []}
    end

    test "an empty field is {nil, []} so it can go straight to a changeset" do
      assert Hostname.split_primary("") == {nil, []}
      assert Hostname.split_primary(nil) == {nil, []}
    end

    test "a value that is not wholly hostnames comes back UNSPLIT" do
      # Splitting a typo turns one mistake into three: a `domain` of "not", plus aliases
      # "a" and "host!" -- three errors about fields the operator never filled in. Handed
      # back whole, the changeset can say one true thing about it.
      assert Hostname.split_primary("not a host!") == {"not a host!", []}
      assert Hostname.split_primary("my app domain") == {"my app domain", []}
    end

    test "a partly-valid list is not split either" do
      assert Hostname.split_primary("example.com, not_a_host") ==
               {"example.com, not_a_host", []}
    end
  end
end
