defmodule HomelabWeb.SecretRevealTest do
  use ExUnit.Case, async: true

  alias HomelabWeb.SecretReveal

  describe "toggle/2" do
    test "adds an id that is not revealed and removes one that is" do
      set = SecretReveal.toggle(MapSet.new(), "2")
      assert MapSet.member?(set, 2)

      assert SecretReveal.toggle(set, "2") == MapSet.new()
    end

    test "a numeric id becomes the integer an index-keyed screen stores" do
      assert SecretReveal.toggle(MapSet.new(), "0") == MapSet.new([0])
      assert SecretReveal.toggle(MapSet.new([0]), 0) == MapSet.new()
    end

    test "a variable name stays a string" do
      assert SecretReveal.toggle(MapSet.new(), "SMTP_PASS") == MapSet.new(["SMTP_PASS"])
    end
  end

  describe "drop_index/2" do
    # The leak this feature could have introduced: the operator reveals row 2, deletes
    # row 0, and row 2's credential slides up into a slot the set still points at — so a
    # different secret is on screen than the one that was asked for.
    test "renumbers the rows that shift up into the hole" do
      assert SecretReveal.drop_index(MapSet.new([2]), 0) == MapSet.new([1])
      assert SecretReveal.drop_index(MapSet.new([0, 3]), 1) == MapSet.new([0, 2])
    end

    test "the deleted row's own reveal goes with it" do
      assert SecretReveal.drop_index(MapSet.new([1]), 1) == MapSet.new()
    end

    test "rows above the hole keep their positions" do
      assert SecretReveal.drop_index(MapSet.new([0, 1]), 2) == MapSet.new([0, 1])
    end
  end
end
