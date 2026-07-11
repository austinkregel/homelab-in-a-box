defmodule HomelabWeb.ChartComponents do
  @moduledoc """
  Lightweight, dependency-free SVG chart components for telemetry.

  Every chart here is **single-series** (one metric over time), so per the data-viz
  guidance there is no legend and no categorical palette — the title names the
  series and one hue carries it. Color is applied via `currentColor` + a Tailwind
  text token (`text-primary`, `text-info`, …) so the marks adapt to light/dark
  theme automatically. Geometry is computed server-side; no JS is required.
  """
  use Phoenix.Component

  # Chart-space viewBox. Rendered responsively via `preserveAspectRatio="none"`
  # so the SVG stretches to its container width while keeping these coordinates.
  @w 100.0
  @spark_h 32.0
  @area_h 120.0

  @doc """
  A compact inline trend line (area + stroke), sized to its container.

  Expects `points` as a list of numbers or a list of `%{value: number}` maps
  (the shape `Homelab.Telemetry.series/1` returns). Renders nothing meaningful
  below two points but degrades gracefully (flat baseline).
  """
  attr :points, :list, required: true
  attr :color, :string, default: "primary"
  attr :class, :string, default: "w-full h-8"

  def sparkline(assigns) do
    values = normalize(assigns.points)
    geom = geometry(values, @spark_h)

    assigns =
      assigns
      |> assign(:w, @w)
      |> assign(:h, @spark_h)
      |> assign(:line, geom.line)
      |> assign(:area, geom.area)
      |> assign(:last, geom.last)
      |> assign(:has_data, geom.has_data)
      |> assign(:text_color, text_color(assigns.color))

    ~H"""
    <svg
      class={[@class, @text_color]}
      viewBox={"0 0 #{@w} #{@h}"}
      preserveAspectRatio="none"
      role="img"
      aria-hidden="true"
    >
      <%= if @has_data do %>
        <path d={@area} fill="currentColor" fill-opacity="0.12" stroke="none" />
        <path
          d={@line}
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
          vector-effect="non-scaling-stroke"
        />
        <circle cx={elem(@last, 0)} cy={elem(@last, 1)} r="1.6" fill="currentColor" />
      <% else %>
        <line
          x1="0"
          y1={@h / 2}
          x2={@w}
          y2={@h / 2}
          stroke="currentColor"
          stroke-opacity="0.2"
          stroke-width="1"
          stroke-dasharray="2 2"
          vector-effect="non-scaling-stroke"
        />
      <% end %>
    </svg>
    """
  end

  @doc """
  A full trend chart: headline current value, min/max context, gridlines, and a
  filled area line over the window. `series` is `[%{recorded_at, value}]`.

  `format` is a 1-arity function turning a raw value into a display string
  (e.g. `&format_percent/1`); it defaults to a plain rounded number.
  """
  attr :series, :list, required: true
  attr :label, :string, required: true
  attr :color, :string, default: "primary"
  attr :format, :any, default: nil
  attr :height_class, :string, default: "h-32"

  def area_chart(assigns) do
    values = normalize(assigns.series)
    geom = geometry(values, @area_h)
    fmt = assigns.format || (&default_format/1)

    {min_v, max_v} = geom.domain
    current = List.last(values)

    assigns =
      assigns
      |> assign(:w, @w)
      |> assign(:h, @area_h)
      |> assign(:line, geom.line)
      |> assign(:area, geom.area)
      |> assign(:has_data, geom.has_data)
      |> assign(:grid, gridlines(@area_h))
      |> assign(:text_color, text_color(assigns.color))
      |> assign(:current_label, if(current, do: fmt.(current), else: "—"))
      |> assign(:min_label, if(geom.has_data, do: fmt.(min_v), else: "—"))
      |> assign(:max_label, if(geom.has_data, do: fmt.(max_v), else: "—"))
      |> assign(:count, length(values))

    ~H"""
    <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-4">
      <div class="flex items-start justify-between mb-2">
        <div>
          <p class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">
            {@label}
          </p>
          <p class={["text-2xl font-bold tracking-tight mt-0.5", @text_color]}>{@current_label}</p>
        </div>
        <div class="text-right text-[11px] text-base-content/30 leading-4">
          <p>max {@max_label}</p>
          <p>min {@min_label}</p>
        </div>
      </div>
      <div class="relative">
        <svg
          class={["w-full", @height_class, @text_color]}
          viewBox={"0 0 #{@w} #{@h}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={@label <> " trend"}
        >
          <line
            :for={y <- @grid}
            x1="0"
            y1={y}
            x2={@w}
            y2={y}
            stroke="currentColor"
            stroke-opacity="0.08"
            stroke-width="1"
            vector-effect="non-scaling-stroke"
          />
          <%= if @has_data do %>
            <path d={@area} fill="currentColor" fill-opacity="0.1" stroke="none" />
            <path
              d={@line}
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linejoin="round"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
          <% end %>
        </svg>
        <p
          :if={!@has_data}
          class="absolute inset-0 flex items-center justify-center text-xs text-base-content/30"
        >
          Collecting data…
        </p>
      </div>
      <p class="text-[11px] text-base-content/30 mt-2">
        {@count} samples over the window
      </p>
    </div>
    """
  end

  # --- Geometry -------------------------------------------------------------

  # Turns a value list into SVG path strings for a chart of the given height.
  # A single point renders a flat line at mid-height; an empty list has no data.
  defp geometry(values, height) do
    case values do
      [] ->
        %{line: "", area: "", last: {0.0, 0.0}, has_data: false, domain: {0.0, 0.0}}

      _ ->
        {min_v, max_v} = domain(values)
        n = length(values)
        pad = height * 0.08

        pts =
          values
          |> Enum.with_index()
          |> Enum.map(fn {v, i} ->
            x = if n == 1, do: @w / 2, else: i / (n - 1) * @w
            y = height - pad - normal(v, min_v, max_v) * (height - 2 * pad)
            {Float.round(x, 2), Float.round(y, 2)}
          end)

        line = "M " <> Enum.map_join(pts, " L ", fn {x, y} -> "#{x} #{y}" end)

        {fx, _} = List.first(pts)
        {lx, _} = List.last(pts)
        area = line <> " L #{lx} #{height} L #{fx} #{height} Z"

        %{line: line, area: area, last: List.last(pts), has_data: true, domain: {min_v, max_v}}
    end
  end

  # Fraction (0..1) of `v` within the domain; a flat series sits mid-band so it
  # doesn't collapse onto the baseline.
  defp normal(_v, min_v, max_v) when max_v == min_v, do: 0.5
  defp normal(v, min_v, max_v), do: (v - min_v) / (max_v - min_v)

  # Pad a domain a touch so the peak/trough don't kiss the chart edges.
  defp domain(values) do
    min_v = Enum.min(values)
    max_v = Enum.max(values)

    cond do
      min_v == max_v and min_v == 0 -> {0.0, 1.0}
      min_v == max_v -> {min_v * 0.95, max_v * 1.05}
      true -> {min_v, max_v}
    end
  end

  defp gridlines(height) do
    Enum.map(1..3, fn i -> Float.round(i / 4 * height, 2) end)
  end

  # --- Value coercion -------------------------------------------------------

  defp normalize(points) do
    points
    |> List.wrap()
    |> Enum.map(fn
      %{value: v} when is_number(v) -> v * 1.0
      v when is_number(v) -> v * 1.0
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp default_format(v) when is_number(v), do: "#{Float.round(v * 1.0, 1)}"
  defp default_format(_), do: "—"

  # Text token drives `currentColor` for the marks; matches the app's gauge hues.
  defp text_color("primary"), do: "text-primary"
  defp text_color("info"), do: "text-info"
  defp text_color("success"), do: "text-success"
  defp text_color("warning"), do: "text-warning"
  defp text_color("error"), do: "text-error"
  defp text_color(_), do: "text-base-content"
end
