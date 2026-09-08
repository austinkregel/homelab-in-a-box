defmodule Homelab.IndexedParamsTest do
  @moduledoc """
  The one place that knows a numbered key is a row and `_unused_0` is not.

  Eight parsers had their own copy of this sort, and every one of them raised
  `ArgumentError` on the marker LiveView posts beside an untouched input — inside
  `handle_event`, so the crash took the LiveView with it and the operator saw their
  edits vanish rather than an error. These tests pin the shape of the payload that did
  it, so a ninth parser cannot reintroduce the sort by hand.
  """
  use ExUnit.Case, async: true

  alias Homelab.IndexedParams

  describe "ordered/1" do
    test "returns rows in numeric key order, not string order" do
      rows = %{"0" => %{"n" => "a"}, "1" => %{"n" => "b"}, "10" => %{"n" => "c"}}

      assert [%{"n" => "a"}, %{"n" => "b"}, %{"n" => "c"}] = IndexedParams.ordered(rows)
    end

    test "the _unused_ marker LiveView posts is dropped, not parsed as an index" do
      rows = %{"_unused_0" => "", "0" => %{"n" => "a"}}

      assert [%{"n" => "a"}] = IndexedParams.ordered(rows)
    end

    test "a marker never displaces the row it shadows" do
      rows = %{
        "_unused_0" => "",
        "_unused_1" => "",
        "1" => %{"n" => "second"},
        "0" => %{"n" => "first"}
      }

      assert [%{"n" => "first"}, %{"n" => "second"}] = IndexedParams.ordered(rows)
    end

    test "a key that merely starts with digits is not an index" do
      assert IndexedParams.ordered(%{"0abc" => %{"n" => "x"}}) == []
    end

    test "the shapes a parser actually receives" do
      assert IndexedParams.ordered(nil) == []
      assert IndexedParams.ordered(%{}) == []
      assert IndexedParams.ordered([%{"n" => "a"}]) == [%{"n" => "a"}]
    end
  end

  describe "without_markers/1" do
    test "keeps every real key and drops every marker" do
      assert IndexedParams.without_markers(%{"_unused_DB_HOST" => "", "DB_HOST" => "db"}) ==
               %{"DB_HOST" => "db"}
    end

    test "leaves a map with no markers exactly as it was" do
      params = %{"0" => %{"n" => "a"}}

      assert IndexedParams.without_markers(params) == params
    end
  end
end
