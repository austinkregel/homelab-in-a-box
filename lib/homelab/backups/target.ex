defmodule Homelab.Backups.Target do
  @moduledoc """
  Where an archive is written and read back.

  Deliberately a resource protocol (`open` / `write` / `close`) rather than something
  that consumes a stream. The writer has to fold over the archive anyway to keep the
  plaintext and ciphertext digests, and driving the loop itself means those digests
  never need a side process to escape from. It also gives resumable uploads somewhere
  to live: the handle carries whatever a target needs to pick up a part-finished
  transfer, without the writer knowing what that is.

  `write/2` takes one frame at a time. A frame is sized so that it is also one S3
  multipart part, so a target never has to buffer or re-chunk what it is given.
  """

  @type config :: map()
  @type handle :: term()

  @doc "Begins writing the object at `key`, returning a handle to feed frames to."
  @callback open(config(), key :: String.t(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc "Appends one frame. Returns the handle to use for the next write."
  @callback write(handle(), iodata()) :: {:ok, handle()} | {:error, term()}

  @doc """
  Finishes the object, returning what the target recorded about it.

  The map carries at least `:bytes`, and a `:checksum` where the target computed one
  of its own — that is the independent check that what arrived is what was sent.
  """
  @callback close(handle()) :: {:ok, map()} | {:error, term()}

  @doc "Discards a part-written object. Never raises; there is nothing to salvage."
  @callback abort(handle()) :: :ok

  @doc "The object's frames, in order, for reading an archive back."
  @callback read_stream(config(), key :: String.t(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Size and, where the target has one, checksum — without transferring the object."
  @callback stat(config(), key :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Keys under `prefix`, each with at least `:key` and `:bytes`."
  @callback list(config(), prefix :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @callback delete(config(), key :: String.t()) :: :ok | {:error, term()}

  @doc "A short stable id for this target kind, as stored on a `backup_targets` row."
  @callback kind() :: String.t()

  @doc "What to call this target in the UI."
  @callback display_name() :: String.t()
end
