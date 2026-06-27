defmodule HomelabWeb.ButtonTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HomelabWeb.CoreComponents

  defp render_button(assigns), do: render_component(&CoreComponents.button/1, assigns)

  test "a labelled button wires the loading hook + conjugated data attributes" do
    html = render_button(%{label: "Save", type: "submit"})

    assert html =~ ~s(phx-hook="ButtonLoading")
    assert html =~ ~s(data-label-root="Save")
    assert html =~ ~s(data-label-gerund="Saving")
    assert html =~ ~s(data-label-past="Saved")
    assert html =~ "data-spinner"
    assert html =~ ~s(<span data-label>Save</span>)
  end

  test "conjugates verb-led phrases" do
    html = render_button(%{label: "Deploy app"})
    assert html =~ ~s(data-label-gerund="Deploying app")
    assert html =~ ~s(data-label-past="Deployed app")
  end

  test "loading={false} renders a plain button with no hook" do
    html = render_button(%{label: "Cancel", loading: false})

    refute html =~ "ButtonLoading"
    refute html =~ "data-spinner"
    assert html =~ "Cancel"
  end

  test "a navigate button renders a link, not the loading hook" do
    html = render_button(%{navigate: "/", inner_block: nil} |> with_slot("Home"))

    assert html =~ "<a"
    refute html =~ "ButtonLoading"
    assert html =~ "Home"
  end

  # Builds the inner_block slot render_component expects for slotted content.
  defp with_slot(assigns, text) do
    Map.put(assigns, :inner_block, [%{__slot__: :inner_block, inner_block: fn _, _ -> text end}])
  end
end
