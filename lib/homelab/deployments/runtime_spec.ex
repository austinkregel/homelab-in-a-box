defmodule Homelab.Deployments.RuntimeSpec do
  @moduledoc """
  The one definition of a container's **privileged runtime**: Linux capabilities,
  device passthrough, and sysctls.

  These are the three settings that decide whether a workload can do anything the
  kernel guards — open a tun device and rewrite a routing table (gluetun and every
  other VPN client), talk to a serial dongle (Zigbee/Z-Wave), or raise a namespaced
  kernel limit. Every producer of one (the deploy wizard, the Runtime card, the
  compose parser, the adoption planner) normalizes through here, and both schemas
  that persist one (`AppTemplate` and `Deployment`'s overrides) validate through here.

  ## Why this refuses rather than repairs

  All three fail *quietly* when they are wrong, which is why they are validated at
  save time rather than handed to the daemon to sort out:

    * a misspelled **capability** is rejected by the daemon with a message that names
      the whole list rather than the typo, and a capability the operator *meant* to
      add but spelled wrong looks identical to one that was never added — the app
      just fails at runtime with a permission error from somewhere deep inside itself;

    * a **device** whose host path does not exist is created by the daemon as a plain
      file inside the container on some storage drivers, so the app opens it, gets
      nothing, and reports a hardware fault;

    * a non-namespaced **sysctl** is rejected outright ("sysctl is not in a separate
      kernel namespace"), which reads as a Docker bug rather than an invalid setting.

  ## Shapes

      capabilities: ["NET_ADMIN"]                    # bare, uppercase, no CAP_ prefix
      devices:      [%{"host_path" => "/dev/net/tun",
                       "container_path" => "/dev/net/tun",
                       "permissions" => "rwm"}]
      sysctls:      %{"net.ipv4.conf.all.src_valid_mark" => "1"}
  """

  import Ecto.Changeset

  # Docker's own capability set (`man 7 capabilities`, minus the ones the daemon does
  # not recognise). Kept explicit so a typo is caught here rather than at deploy.
  @capabilities ~w(
    AUDIT_CONTROL AUDIT_READ AUDIT_WRITE BLOCK_SUSPEND BPF CHECKPOINT_RESTORE CHOWN
    DAC_OVERRIDE DAC_READ_SEARCH FOWNER FSETID IPC_LOCK IPC_OWNER KILL LEASE
    LINUX_IMMUTABLE MAC_ADMIN MAC_OVERRIDE MKNOD NET_ADMIN NET_BIND_SERVICE
    NET_BROADCAST NET_RAW PERFMON SETFCAP SETGID SETPCAP SETUID SYS_ADMIN SYS_BOOT
    SYS_CHROOT SYS_MODULE SYS_NICE SYS_PACCT SYS_PTRACE SYS_RAWIO SYS_RESOURCE
    SYS_TIME SYS_TTY_CONFIG SYSLOG WAKE_ALARM
  )

  # Accepted only for dropping (`--cap-drop ALL`). Adding every capability is
  # `privileged`, which this deliberately does not offer.
  @drop_all "ALL"

  # Capabilities that reach past the container: kernel modules, raw I/O, other
  # processes' memory, the host clock, the host's packet filter. The UI warns on
  # these; it does not refuse them, because NET_ADMIN is exactly what a VPN client
  # legitimately needs.
  @privileged_capabilities ~w(
    AUDIT_CONTROL BPF DAC_READ_SEARCH LINUX_IMMUTABLE MAC_ADMIN MAC_OVERRIDE MKNOD
    NET_ADMIN NET_RAW PERFMON SYS_ADMIN SYS_BOOT SYS_MODULE SYS_PTRACE SYS_RAWIO
    SYS_TIME
  )

  # The only sysctls Docker will set on a container. Everything else lives in a
  # namespace the container does not own, and the daemon refuses it rather than
  # silently applying it to the host.
  #
  # `net.*` additionally requires the container to have its OWN network namespace —
  # see `validate_sysctls_for_network/3`.
  @sysctl_prefixes ~w(net. fs.mqueue.)
  @sysctl_exact ~w(
    kernel.msgmax kernel.msgmnb kernel.msgmni kernel.sem kernel.shmall kernel.shmmax
    kernel.shmmni kernel.shm_rmid_forced
  )

  @device_permissions ~w(r w m)

  @doc "Every capability that can be added or dropped."
  def capabilities, do: @capabilities

  @doc "True when adding this capability meaningfully widens the container's reach."
  def privileged_capability?(cap), do: normalize_capability(cap) in @privileged_capabilities

  # --- Capabilities ---

  @doc """
  Normalizes a list of capability names: trimmed, uppercased, `CAP_` prefix removed.

  Docker accepts `NET_ADMIN` and `CAP_NET_ADMIN` interchangeably and compose files in
  the wild use both, so they are folded to one form here rather than being stored as
  two spellings of the same permission.
  """
  def parse_capabilities(nil), do: []

  def parse_capabilities(caps) when is_binary(caps) do
    caps
    |> String.split([",", "\n"], trim: true)
    |> parse_capabilities()
  end

  def parse_capabilities(caps) when is_list(caps) do
    caps
    |> Enum.map(&normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_capabilities(_caps), do: []

  defp normalize_capability(cap) when is_binary(cap) do
    cap
    |> String.trim()
    |> String.upcase()
    |> String.replace_prefix("CAP_", "")
  end

  defp normalize_capability(_cap), do: ""

  @doc """
  Validates a `{:array, :string}` capabilities field.

  `ALL` is accepted only on a drop field: dropping everything is a hardening move,
  adding everything is `privileged` by another name.
  """
  def validate_capabilities(changeset, field, opts \\ []) do
    allow_all? = Keyword.get(opts, :allow_all, false)

    case get_change(changeset, field) do
      nil ->
        changeset

      caps when is_list(caps) ->
        allowed = if allow_all?, do: [@drop_all | @capabilities], else: @capabilities

        caps
        |> parse_capabilities()
        |> Enum.reject(&(&1 in allowed))
        |> case do
          [] ->
            changeset

          unknown ->
            add_error(
              changeset,
              field,
              "unknown Linux #{if length(unknown) == 1, do: "capability", else: "capabilities"}: " <>
                "#{Enum.join(unknown, ", ")}"
            )
        end

      _ ->
        add_error(changeset, field, "must be a list")
    end
  end

  # --- Devices ---

  @doc """
  Normalizes indexed form params (`%{"0" => %{...}}`) or a plain list into an ordered
  list of canonical, string-keyed device maps. Rows with no host path are dropped — a
  blank row is an operator who added one and changed their mind, not an error.
  """
  def parse_devices(devices) do
    devices
    |> parse_device_rows()
    |> Enum.reject(&blank?(&1["host_path"]))
  end

  @doc """
  Like `parse_devices/1`, but KEEPS blank rows — for a live-editing form, where a
  just-added row has to survive the next change event instead of vanishing under the
  operator's cursor.
  """
  def parse_device_rows(nil), do: []

  def parse_device_rows(devices) when is_map(devices) do
    devices
    |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} -> normalize_device(row) end)
  end

  def parse_device_rows(devices) when is_list(devices) do
    Enum.map(devices, &normalize_device/1)
  end

  @doc """
  Canonicalizes a single device.

  Accepts the compose string forms (`"/dev/net/tun"`, `"/dev/sda:/dev/xvda"`,
  `"/dev/ttyUSB0:/dev/ttyUSB0:rw"`) as well as a map. A missing container path
  defaults to the host path, which is both compose's rule and what an operator means
  every time but the rare renaming case.
  """
  def normalize_device(device) when is_binary(device) do
    case String.split(device, ":") do
      [host] -> build_device(host, host, nil)
      [host, container] -> build_device(host, container, nil)
      [host, container, perms | _rest] -> build_device(host, container, perms)
    end
  end

  def normalize_device(device) when is_map(device) do
    host = trim(device["host_path"] || device["source"] || device["path"])
    container = trim(device["container_path"] || device["target"])

    build_device(host, container, device["permissions"])
  end

  def normalize_device(_device), do: build_device(nil, nil, nil)

  defp build_device(host, container, permissions) do
    host = trim(host)

    %{
      "host_path" => host,
      "container_path" => trim(container) || host,
      "permissions" => normalize_permissions(permissions)
    }
  end

  # Docker's default for `--device` is full access; anything narrower has to be asked
  # for. An unparseable value falls back to the default rather than silently locking
  # the app out of its own device.
  defp normalize_permissions(permissions) when is_binary(permissions) do
    cleaned =
      permissions
      |> String.trim()
      |> String.downcase()
      |> String.graphemes()
      |> Enum.filter(&(&1 in @device_permissions))
      |> Enum.uniq()
      |> Enum.join()

    if cleaned == "", do: "rwm", else: cleaned
  end

  defp normalize_permissions(_permissions), do: "rwm"

  @doc """
  Validates a `{:array, :map}` devices field.

  Refuses, rather than repairs:

    * a non-absolute host path — the daemon reads it as a relative path against `/`
      and creates something that is not the device the operator named;

    * a duplicate container path — Docker takes one and drops the other, and which
      one it takes decides whether the app finds its hardware;

    * permissions outside `rwm`.
  """
  def validate_devices(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      devices when is_list(devices) ->
        devices
        |> Enum.reduce(changeset, &validate_device(&1, &2, field))
        |> validate_unique_device_paths(devices, field)

      _ ->
        add_error(changeset, field, "must be a list")
    end
  end

  defp validate_device(device, changeset, field) do
    raw_permissions = raw_permissions(device)
    device = normalize_device(device)

    cond do
      not absolute?(device["host_path"]) ->
        add_error(
          changeset,
          field,
          "a device needs an absolute host path (got #{inspect(device["host_path"])})"
        )

      not absolute?(device["container_path"]) ->
        add_error(
          changeset,
          field,
          "a device needs an absolute path inside the container " <>
            "(got #{inspect(device["container_path"])})"
        )

      not valid_permissions?(raw_permissions) ->
        add_error(
          changeset,
          field,
          "device permissions may only contain r (read), w (write) and m (mknod) — " <>
            "got #{inspect(raw_permissions)}"
        )

      true ->
        changeset
    end
  end

  # The normalized value silently drops junk so a bad form value can never lock an app
  # out of its device; validation reads the RAW value so the operator still hears about
  # it.
  defp raw_permissions(device) when is_map(device), do: device["permissions"]
  defp raw_permissions(device) when is_binary(device), do: nil
  defp raw_permissions(_device), do: nil

  defp valid_permissions?(nil), do: true

  defp valid_permissions?(permissions) when is_binary(permissions) do
    trimmed = String.trim(permissions)

    trimmed == "" or
      trimmed
      |> String.downcase()
      |> String.graphemes()
      |> Enum.all?(&(&1 in @device_permissions))
  end

  defp valid_permissions?(_permissions), do: false

  defp validate_unique_device_paths(changeset, devices, field) do
    paths = Enum.map(devices, &normalize_device(&1)["container_path"])

    if length(Enum.uniq(paths)) == length(paths),
      do: changeset,
      else: add_error(changeset, field, "two devices cannot share a path inside the container")
  end

  # --- Sysctls ---

  @doc """
  Normalizes sysctls into a string-keyed map.

  Accepts the map form (`%{"net.core.somaxconn" => 1024}`) and compose's list form
  (`["net.core.somaxconn=1024"]`); values are stringified because the Docker API takes
  them as strings and an integer here is rejected.
  """
  def parse_sysctls(nil), do: %{}

  def parse_sysctls(sysctls) when is_list(sysctls) do
    sysctls
    |> Enum.flat_map(fn
      entry when is_binary(entry) ->
        case String.split(entry, "=", parts: 2) do
          [key, value] -> [{String.trim(key), String.trim(value)}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  def parse_sysctls(sysctls) when is_map(sysctls) do
    sysctls
    |> Enum.reject(fn {key, _value} -> blank?(to_string(key)) end)
    |> Map.new(fn {key, value} -> {String.trim(to_string(key)), to_string(value)} end)
  end

  def parse_sysctls(_sysctls), do: %{}

  @doc """
  Validates a `:map` sysctls field: every key must live in a namespace the container
  actually owns, or the daemon refuses the create.
  """
  def validate_sysctls(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      sysctls when is_map(sysctls) ->
        sysctls
        |> parse_sysctls()
        |> Map.keys()
        |> Enum.reject(&namespaced_sysctl?/1)
        |> case do
          [] ->
            changeset

          unknown ->
            add_error(
              changeset,
              field,
              "these sysctls are not in a namespace a container owns, so Docker refuses " <>
                "them: #{Enum.join(unknown, ", ")}"
            )
        end

      _ ->
        add_error(changeset, field, "must be a map")
    end
  end

  @doc """
  True when a sysctl key names something a container has its own copy of.
  """
  def namespaced_sysctl?(key) when is_binary(key) do
    key in @sysctl_exact or Enum.any?(@sysctl_prefixes, &String.starts_with?(key, &1))
  end

  def namespaced_sysctl?(_key), do: false

  @doc """
  True when a sysctl key needs the container to have its OWN network namespace.

  A container that joins the host's or another container's namespace does not own the
  network stack it is using, and the daemon rejects any `net.*` sysctl on it rather
  than applying it to the namespace's real owner.
  """
  def network_sysctl?(key) when is_binary(key), do: String.starts_with?(key, "net.")
  def network_sysctl?(_key), do: false

  # --- Shared helpers ---

  defp absolute?(path) when is_binary(path),
    do: String.starts_with?(path, "/") and String.trim(path) != "/"

  defp absolute?(_path), do: false

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp trim(nil), do: nil

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value
end
