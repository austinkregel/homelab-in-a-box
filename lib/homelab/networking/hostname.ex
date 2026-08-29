defmodule Homelab.Networking.Hostname do
  @moduledoc """
  Parsing, normalization and validation for a single routable hostname.

  Every hostname the platform stores ends up interpolated into a Traefik `Host(...)`
  rule and handed to Let's Encrypt as an ACME identifier. Neither component validates
  it for us in any useful way: Traefik takes a rule it cannot parse, declines to build
  the router, and logs it once at startup; Let's Encrypt rejects the order and the app
  is simply never reachable over TLS. Both failures land far from the text field that
  caused them, hours later, in a log nobody is reading.

  `communication.ventures,matrix.communication.ventures` is what that looks like in
  practice — an operator with two hostnames and one input box, comma-separating them
  the way any other tool would accept. It became a single router whose rule was
  ``Host(`communication.ventures,matrix.communication.ventures`)`` and one ACME order
  for a name that cannot exist. So this module exists to be the ONE place that decides
  what a hostname is, and `split/1` exists so that a multi-host value is recognised as
  the list it obviously is rather than rejected as a typo.

  Normalization is deliberately forgiving of how a host reaches us — pasted from a
  browser bar with a scheme and a path, typed with a trailing dot, capitalised — and
  strict about what comes out. `valid?/1` is applied to normalized output, so
  everything it rejects is genuinely not a hostname rather than merely untidy.
  """

  # RFC 1123 with the tightening the use case actually requires: at least two labels.
  # A single-label `localhost` is a valid hostname and a useless public route -- it can
  # never carry a certificate -- and requiring the dot is what catches a path or a bare
  # app name typed into a domain field.
  @label ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @max_length 253
  @max_label 63

  @doc """
  Canonical form of a single hostname, or `nil` when there is nothing left of it.

  Strips what a paste carries and a Host rule cannot use — scheme, path, port, trailing
  dot, surrounding whitespace, case. It does NOT split: a comma-joined value normalizes
  to a comma-joined string, which `valid?/1` then rejects. Splitting is `split/1`'s job
  precisely because it changes how many things there are, and only a caller that can
  store more than one may decide to do that.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> strip_scheme()
    |> strip_path()
    |> strip_port()
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize(_host), do: nil

  # A hostname pasted out of a browser bar arrives as a URL. Taking the scheme off is
  # what makes that paste work rather than fail validation for a reason the operator
  # cannot see (the `//` is not visibly wrong to a human reading their own input).
  defp strip_scheme(host) do
    case String.split(host, "://", parts: 2) do
      [_scheme, rest] -> rest
      [only] -> only
    end
  end

  # Everything from the first slash is a path, and a Host rule has no room for one.
  # Dropping it rather than rejecting keeps `https://matrix.example.com/` working; a
  # path that was MEANT to scope the route belongs in `path_prefix`, a separate field.
  defp strip_path(host), do: host |> String.split("/", parts: 2) |> hd()

  # `example.com:8443` is the other half of a browser paste. The port a route listens on
  # is the entrypoint's (80/443), never the Host rule's, so this is unambiguous noise.
  defp strip_port(host), do: host |> String.split(":", parts: 2) |> hd()

  @doc """
  True when `host` is a single, routable, fully-qualified hostname.

  Normalizes first, so the answer is about the value that would actually be STORED
  rather than the value as typed — `" Matrix.Example.COM. "` is valid because what we
  keep is `matrix.example.com`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(host) do
    case normalize(host) do
      nil -> false
      normalized -> valid_normalized?(normalized)
    end
  end

  defp valid_normalized?(host) do
    labels = String.split(host, ".")

    String.length(host) <= @max_length and
      length(labels) >= 2 and
      Enum.all?(labels, &valid_label?/1)
  end

  defp valid_label?(label) do
    String.length(label) <= @max_label and Regex.match?(@label, label)
  end

  @doc """
  Split a free-text host field into the list of hostnames it names.

  Separators are commas and whitespace, which between them cover every way an operator
  writes "these two names" into one box. Each result is normalized, blanks are dropped
  and duplicates collapse (keeping first-seen order), so `split/1` on a single ordinary
  hostname returns exactly `[that_hostname]` and the multi-host case needs no special
  handling by callers.

  Note that this does NOT filter out invalid entries. A caller splitting operator input
  wants `["not a host!"]` to survive as far as the changeset, so the error names what
  was typed instead of the field silently emptying itself.
  """
  @spec split(term()) :: [String.t()]
  def split(value) when is_binary(value) do
    value
    |> String.split([",", ";", "\n", "\r", "\t", " "], trim: true)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def split(_value), do: []

  @doc """
  True when `value` names SEVERAL hostnames — more than one piece, and every piece a
  hostname in its own right.

  The second half is what stops this being "contains a separator". `split/1` breaks on
  whitespace, so any typed sentence yields several pieces; `not a host!` is one mistake,
  not three hostnames, and every caller that treats it as a list makes that one mistake
  worse. Callers use this to decide whether a field is a LIST before acting like it is.
  """
  @spec multi_host?(term()) :: boolean()
  def multi_host?(value) do
    case split(value) do
      [] -> false
      [_single] -> false
      hosts -> Enum.all?(hosts, &valid?/1)
    end
  end

  @doc """
  Split a host field into `{primary, aliases}` — the main domain and everything else.

  This is the shape the platform stores: `Deployment.domain` carries one name and
  `Deployment.additional_domains` carries the rest, so a form with a single input can
  still express the root + subdomain pair that made this necessary. The FIRST name wins
  the primary slot, which matches how the field reads left to right.

  A value that is not WHOLLY hostnames comes back unsplit, in the primary slot. Splitting
  it would turn one typo into several: `not a host!` becomes a `domain` of `not` plus
  aliases `a` and `host!`, and the operator gets three errors about fields they never
  filled in instead of one about the field they did. Handing the value back whole is what
  lets the changeset say a single true thing about it.

  Returns `{nil, []}` for an empty field, so a caller can pass the result straight to a
  changeset without checking for the blank case.
  """
  @spec split_primary(term()) :: {String.t() | nil, [String.t()]}
  def split_primary(value) do
    if multi_host?(value) do
      [primary | aliases] = split(value)
      {primary, aliases}
    else
      {normalize(value), []}
    end
  end
end
