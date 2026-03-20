defmodule HomelabWeb.Api.V1.ErrorJSON do
  def render("error.json", %{changeset: changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{errors: errors}
  end

  def render("error.json", %{status: status, message: message}) do
    %{errors: %{detail: message, status: status}}
  end
end
