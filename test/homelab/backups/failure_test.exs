defmodule Homelab.Backups.FailureTest do
  use ExUnit.Case, async: true

  alias Homelab.Backups.Failure

  describe "describe/1" do
    test "names the condition rather than the term" do
      described = Failure.describe({:restic_missing, "restic is not installed or not on PATH"})

      assert described.summary =~ "not installed"
      refute described.summary =~ ":restic_missing"
      assert described.fix =~ "Settings"
    end

    test "keeps the original term as detail" do
      described = Failure.describe({:source_missing, "/srv/data/plex"})

      assert described.summary =~ "/srv/data/plex"
      assert described.detail =~ ":source_missing"
    end

    test "surfaces tar's own message as the next thing to look at" do
      described =
        Failure.describe({:tar_failed, 2, "tar: /srv/x: Cannot open: Permission denied\nmore"})

      assert described.summary =~ "tar exited 2"
      assert described.fix == "tar: /srv/x: Cannot open: Permission denied"
    end

    test "distinguishes the integrity failures from each other" do
      assert Failure.describe({:frame_tampered, 3}).summary =~ "Chunk 3"
      assert Failure.describe({:frame_truncated, 4}).summary =~ "incomplete"
      assert Failure.describe({:frame_out_of_order, 1, 2}).summary =~ "out of order"
      assert Failure.describe({:frame_count_mismatch, 10, 9}).summary =~ "9 of 10"
      assert Failure.describe(:key_mismatch).summary =~ "different recovery key"
    end

    test "an unconfigured root explains itself, so its own text is the summary" do
      raised =
        assert_raise ArgumentError, fn ->
          Homelab.Backups.Targets.LocalDisk.root!(%{})
        end

      described = Failure.describe(Exception.message(raised))
      assert described.summary =~ "No backup root is configured"
    end

    test "an exception struct is described by its message" do
      described = Failure.describe(%RuntimeError{message: "something specific went wrong"})

      assert described.summary == "something specific went wrong"
    end

    test "an unrecognised term still produces something sayable" do
      described = Failure.describe({:something_new, %{a: 1}})

      assert described.summary == "The backup failed."
      assert described.detail =~ ":something_new"
    end
  end

  describe "to_message/1 and from_message/1" do
    test "round-trips summary, fix and detail" do
      message = Failure.to_message({:source_missing, "/srv/data"})
      parsed = Failure.from_message(message)

      assert parsed.summary =~ "/srv/data"
      assert parsed.fix =~ "managed root"
      assert parsed.detail =~ ":source_missing"
    end

    test "round-trips a failure that has no fix" do
      message = Failure.to_message(%RuntimeError{message: "plain failure"})
      parsed = Failure.from_message(message)

      assert parsed.summary == "plain failure"
      assert parsed.detail =~ "RuntimeError"
    end

    # Rows written before this existed hold a bare inspected term. They must still
    # render rather than crashing the page that finally shows them.
    test "tolerates a legacy row holding only an inspected term" do
      parsed = Failure.from_message(~s({:restic_missing, "restic is not installed"}))

      assert parsed.summary == ~s({:restic_missing, "restic is not installed"})
      assert parsed.fix == nil
    end

    test "tolerates no reason at all" do
      parsed = Failure.from_message(nil)

      assert parsed.summary =~ "No reason was recorded"
      assert parsed.detail == ""
    end
  end
end
