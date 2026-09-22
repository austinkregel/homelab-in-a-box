defmodule Homelab.Backups.Failure do
  @moduledoc """
  Turns a backup failure into something an operator can act on.

  A failed backup used to record `inspect(reason)` and nothing else, so the row read
  `{:restic_missing, "restic is not installed or not on PATH"}` — accurate, and no help
  to anyone deciding what to do about it. Worse, that string was never rendered
  anywhere, so the only way to see a reason was the flash that appeared for a few
  seconds after clicking the button.

  Each failure gets three parts, and all three are kept:

    * `summary` — the condition, in one sentence.
    * `fix` — the single next action, where there is an obvious one.
    * `detail` — the original term, for when the summary is not enough.
  """

  @type described :: %{summary: String.t(), fix: String.t() | nil, detail: String.t()}

  @doc "Describes a failure reason."
  @spec describe(term()) :: described()
  def describe(reason) do
    reason |> classify() |> Map.put(:detail, detail(reason))
  end

  @doc """
  The form stored in `error_message`: summary, fix, then the original term.

  One column has to carry all three until runs are a table of their own, and losing
  the original term to make room for prose would trade one blind spot for another.
  """
  @spec to_message(term()) :: String.t()
  def to_message(reason) do
    %{summary: summary, fix: fix, detail: detail} = describe(reason)

    [summary, fix, detail]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Splits a stored message back into its parts for rendering.

  Tolerates rows written before this existed, which hold a bare inspected term: those
  come back as detail with no summary, which is exactly what they are.
  """
  @spec from_message(String.t() | nil) :: described()
  def from_message(nil), do: %{summary: "No reason was recorded.", fix: nil, detail: ""}

  def from_message(message) do
    case String.split(message, "\n\n", parts: 3) do
      [summary, fix, detail] -> %{summary: summary, fix: fix, detail: detail}
      [summary, detail] -> %{summary: summary, fix: nil, detail: detail}
      [only] -> %{summary: only, fix: nil, detail: ""}
    end
  end

  # -- classification --

  defp classify({:restic_missing, _}) do
    %{
      summary: "The backup program is not installed in this container, so nothing ran.",
      fix: "Configure a backup target under Settings → Backups."
    }
  end

  defp classify({:restic_error, status, output}) do
    %{
      summary: "The backup program exited with status #{status}.",
      fix: first_line(output)
    }
  end

  defp classify({:source_missing, path}) do
    %{
      summary: "There is nothing at #{path} to back up.",
      fix:
        "Check that the managed root is mounted into this container and that the " <>
          "deployment has written data."
    }
  end

  defp classify({:tar_failed, status, stderr}) do
    %{
      summary: "Reading the volume failed (tar exited #{status}), so the archive is incomplete.",
      fix: first_line(stderr)
    }
  end

  defp classify({:target_unavailable, _}) do
    %{
      summary: "The backup destination could not be reached, so nothing was written.",
      fix: "Check the target's endpoint and credentials under Settings → Backups."
    }
  end

  defp classify({:target_write_failed, _}) do
    %{
      summary: "The destination refused a write part-way through; the archive was discarded.",
      fix: "Check free space and credentials on the target."
    }
  end

  defp classify({:part_failed, number, status, _}) do
    %{
      summary: "Uploading part #{number} failed with status #{status}.",
      fix: "Check the bucket's permissions and that the credentials allow multipart uploads."
    }
  end

  defp classify({:too_many_parts, max}) do
    %{
      summary: "The volume needs more than #{max} parts at the configured frame size.",
      fix: "Raise the frame size for this volume."
    }
  end

  defp classify(:key_mismatch) do
    %{
      summary: "This archive was written under a different recovery key.",
      fix: "Restore the recovery key this archive was made with, or use a newer archive."
    }
  end

  defp classify({:digest_mismatch, _, _}) do
    %{
      summary: "The restored bytes do not match what was backed up; nothing was written.",
      fix: "Treat this archive as unusable and check the storage it came from."
    }
  end

  defp classify({:frame_tampered, index}) do
    %{
      summary: "Chunk #{index} of the archive is corrupt or was altered.",
      fix: "Treat this archive as unusable and check the storage it came from."
    }
  end

  defp classify({:frame_truncated, index}) do
    %{summary: "Chunk #{index} of the archive is incomplete.", fix: storage_fix()}
  end

  defp classify({:frame_out_of_order, expected, got}) do
    %{
      summary: "The archive's chunks are out of order (expected #{expected}, found #{got}).",
      fix: storage_fix()
    }
  end

  defp classify({:frame_count_mismatch, expected, got}) do
    %{
      summary: "The archive is short: #{got} of #{expected} chunks are present.",
      fix: storage_fix()
    }
  end

  defp classify({:archive_exception, message}) do
    %{summary: "The backup stopped on an unexpected error.", fix: first_line(message)}
  end

  # `PermanentHome.managed_root/0` and the local target both raise with a full
  # explanation when they are unconfigured, so that text IS the summary.
  defp classify(message) when is_binary(message) do
    %{summary: first_line(message), fix: nil}
  end

  defp classify(%{__struct__: _} = exception) do
    %{summary: first_line(Exception.message(exception)), fix: nil}
  end

  defp classify(_other) do
    %{summary: "The backup failed.", fix: nil}
  end

  defp storage_fix, do: "Treat this archive as unusable and check the storage it came from."

  defp first_line(nil), do: nil

  defp first_line(text) when is_binary(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      line -> String.slice(line, 0, 300)
    end
  end

  defp first_line(_), do: nil

  defp detail(reason) when is_binary(reason), do: String.slice(reason, 0, 2_000)
  defp detail(reason), do: reason |> inspect(limit: :infinity) |> String.slice(0, 2_000)
end
