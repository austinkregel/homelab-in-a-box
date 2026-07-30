defmodule HomelabWeb.Api.V1.ErrorJSON do
  # Same traversal the LiveViews use — see `HomelabWeb.ChangesetErrors`. This one keeps
  # the field-keyed map, because a JSON client wants to know WHICH field was refused.
  def render("error.json", %{changeset: changeset}) do
    %{errors: HomelabWeb.ChangesetErrors.to_map(changeset)}
  end

  def render("error.json", %{status: status, message: message}) do
    %{errors: %{detail: message, status: status}}
  end
end
