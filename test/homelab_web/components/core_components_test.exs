defmodule HomelabWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HomelabWeb.CoreComponents

  # ---- helpers -------------------------------------------------------------

  defp inner_slot(text) when is_binary(text) do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> text end}]
  end

  defp named_slot(name, text, attrs \\ %{}) do
    [Map.merge(%{__slot__: name, inner_block: fn _, _ -> text end}, attrs)]
  end

  # ==========================================================================
  # flash/1
  # ==========================================================================

  describe "flash/1" do
    test "renders info kind with inner message, icon and styling" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          inner_block: inner_slot("Welcome back!")
        })

      assert html =~ "Welcome back!"
      assert html =~ "alert-info"
      assert html =~ "hero-information-circle"
      assert html =~ ~s(role="alert")
      assert html =~ ~s(id="flash-info")
      refute html =~ "alert-error"
      refute html =~ "hero-exclamation-circle"
    end

    test "renders error kind with its icon and styling" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :error,
          inner_block: inner_slot("Something broke")
        })

      assert html =~ "Something broke"
      assert html =~ "alert-error"
      assert html =~ "hero-exclamation-circle"
      assert html =~ ~s(id="flash-error")
      refute html =~ "alert-info"
      refute html =~ "hero-information-circle"
    end

    test "renders a title when provided" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          title: "Heads up",
          inner_block: inner_slot("body text")
        })

      assert html =~ "Heads up"
      assert html =~ "font-semibold"
      assert html =~ "body text"
    end

    test "omits the title paragraph when no title given" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          inner_block: inner_slot("only body")
        })

      refute html =~ "font-semibold"
      assert html =~ "only body"
    end

    test "pulls message from the flash map when no inner block" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          flash: %{"info" => "from flash map"}
        })

      assert html =~ "from flash map"
    end

    test "renders nothing when there is no message at all" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          flash: %{}
        })

      refute html =~ "role=\"alert\""
      refute html =~ "alert-info"
    end

    test "honors a custom id" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          id: "my-flash",
          inner_block: inner_slot("hi")
        })

      assert html =~ ~s(id="my-flash")
    end

    test "always renders a close button with accessible label" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          inner_block: inner_slot("hi")
        })

      assert html =~ "aria-label=\"close\""
      assert html =~ "hero-x-mark"
    end
  end

  # ==========================================================================
  # input/1 — text (default)
  # ==========================================================================

  describe "input/1 text" do
    test "renders a default text input with name, id and value" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          id: "title-id",
          value: "hello"
        })

      assert html =~ ~s(type="text")
      assert html =~ ~s(name="title")
      assert html =~ ~s(id="title-id")
      assert html =~ ~s(value="hello")
      assert html =~ "input"
    end

    test "renders a label when provided" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          value: "",
          label: "Title"
        })

      assert html =~ "Title"
      assert html =~ "label"
    end

    test "omits the label span when no label given" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          value: ""
        })

      refute html =~ ~s(class="label mb-1")
    end

    test "renders error class and error message when errors present" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          value: "",
          errors: ["is required"]
        })

      assert html =~ "input-error"
      assert html =~ "is required"
      assert html =~ "hero-exclamation-circle"
      assert html =~ "text-error"
    end

    test "no error markup when errors empty" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          value: ""
        })

      refute html =~ "input-error"
      refute html =~ "text-error"
    end

    test "supports a custom class override" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "title",
          value: "",
          class: "my-custom-input"
        })

      assert html =~ "my-custom-input"
    end
  end

  # ==========================================================================
  # input/1 — other html types (email, password)
  # ==========================================================================

  describe "input/1 type variants" do
    test "renders an email input" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "email",
          value: "a@b.com",
          type: "email"
        })

      assert html =~ ~s(type="email")
      assert html =~ ~s(value="a@b.com")
    end

    test "renders a password input" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "pw",
          value: "secret",
          type: "password"
        })

      assert html =~ ~s(type="password")
    end

    test "renders a hidden input without wrapper/label" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "token",
          value: "abc",
          type: "hidden"
        })

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(name="token")
      assert html =~ ~s(value="abc")
      refute html =~ "fieldset"
    end
  end

  # ==========================================================================
  # input/1 — checkbox
  # ==========================================================================

  describe "input/1 checkbox" do
    test "renders an unchecked checkbox plus the hidden false input" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "agree",
          type: "checkbox",
          value: false
        })

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(type="hidden")
      assert html =~ ~s(value="false")
      assert html =~ ~s(value="true")
      assert html =~ "checkbox checkbox-sm"
      refute html =~ "checked"
    end

    test "renders a checked checkbox for a truthy value" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "agree",
          type: "checkbox",
          value: true
        })

      assert html =~ "checked"
    end

    test "renders the label text next to the checkbox" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "agree",
          type: "checkbox",
          value: false,
          label: "I agree"
        })

      assert html =~ "I agree"
    end

    test "renders checkbox errors" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "agree",
          type: "checkbox",
          value: false,
          errors: ["must be accepted"]
        })

      assert html =~ "must be accepted"
      assert html =~ "text-error"
    end
  end

  # ==========================================================================
  # input/1 — select
  # ==========================================================================

  describe "input/1 select" do
    test "renders a select with options" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "role",
          type: "select",
          value: "admin",
          options: [Admin: "admin", User: "user"]
        })

      assert html =~ "<select"
      assert html =~ ~s(name="role")
      assert html =~ "Admin"
      assert html =~ "User"
      assert html =~ ~s(value="admin")
      # preselected option
      assert html =~ ~s(<option selected value="admin">)
    end

    test "renders a prompt option when given" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "role",
          type: "select",
          value: nil,
          prompt: "Choose...",
          options: [Admin: "admin"]
        })

      assert html =~ "Choose..."
      assert html =~ ~s(<option value="">)
    end

    test "renders a multiple select" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "roles",
          type: "select",
          value: nil,
          multiple: true,
          options: [Admin: "admin", User: "user"]
        })

      assert html =~ "multiple"
    end

    test "renders select error styling and message" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "role",
          type: "select",
          value: nil,
          options: [Admin: "admin"],
          errors: ["bad role"]
        })

      assert html =~ "select-error"
      assert html =~ "bad role"
    end

    test "renders a select label" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "role",
          type: "select",
          value: nil,
          label: "Role",
          options: [Admin: "admin"]
        })

      assert html =~ "Role"
    end
  end

  # ==========================================================================
  # input/1 — textarea
  # ==========================================================================

  describe "input/1 textarea" do
    test "renders a textarea with its value as content" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "bio",
          type: "textarea",
          value: "some text"
        })

      assert html =~ "<textarea"
      assert html =~ ~s(name="bio")
      assert html =~ "some text"
      assert html =~ "textarea"
    end

    test "renders textarea label and error" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "bio",
          type: "textarea",
          value: "",
          label: "Bio",
          errors: ["too long"]
        })

      assert html =~ "Bio"
      assert html =~ "textarea-error"
      assert html =~ "too long"
    end

    test "no error class on a clean textarea" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "bio",
          type: "textarea",
          value: ""
        })

      refute html =~ "textarea-error"
    end
  end

  # ==========================================================================
  # input/1 — FormField path
  # ==========================================================================

  describe "input/1 with a FormField" do
    test "derives name, id and value from the form field" do
      field = Phoenix.Component.to_form(%{"email" => "user@example.com"})[:email]

      html = render_component(&CoreComponents.input/1, %{field: field, type: "email"})

      assert html =~ ~s(name="email")
      assert html =~ ~s(value="user@example.com")
      assert html =~ ~s(type="email")
    end

    test "appends [] to the name for a multiple field" do
      field = Phoenix.Component.to_form(%{"tags" => ["a"]})[:tags]

      html =
        render_component(&CoreComponents.input/1, %{
          field: field,
          type: "select",
          multiple: true,
          options: [A: "a", B: "b"]
        })

      assert html =~ ~s(name="tags[]")
    end
  end

  # ==========================================================================
  # header/1
  # ==========================================================================

  describe "header/1" do
    test "renders the title from the inner block" do
      html =
        render_component(&CoreComponents.header/1, %{inner_block: inner_slot("Page Title")})

      assert html =~ "Page Title"
      assert html =~ "<h1"
    end

    test "renders a subtitle slot when present" do
      html =
        render_component(&CoreComponents.header/1, %{
          inner_block: inner_slot("Title"),
          subtitle: named_slot(:subtitle, "A subtitle")
        })

      assert html =~ "A subtitle"
      assert html =~ "text-base-content/70"
    end

    test "omits the subtitle paragraph when absent" do
      html =
        render_component(&CoreComponents.header/1, %{inner_block: inner_slot("Title")})

      refute html =~ "text-base-content/70"
    end

    test "renders an actions slot and applies the flex layout class" do
      html =
        render_component(&CoreComponents.header/1, %{
          inner_block: inner_slot("Title"),
          actions: named_slot(:actions, "DO IT")
        })

      assert html =~ "DO IT"
      assert html =~ "justify-between"
    end

    test "does not apply the flex layout class without actions" do
      html =
        render_component(&CoreComponents.header/1, %{inner_block: inner_slot("Title")})

      refute html =~ "justify-between"
    end
  end

  # ==========================================================================
  # table/1
  # ==========================================================================

  describe "table/1" do
    test "renders headers and a row per item" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}],
          col: [
            %{
              __slot__: :col,
              label: "ID",
              inner_block: fn _, row -> Integer.to_string(row.id) end
            },
            %{
              __slot__: :col,
              label: "Name",
              inner_block: fn _, row -> row.name end
            }
          ]
        })

      assert html =~ "<table"
      assert html =~ ">ID</th>"
      assert html =~ ">Name</th>"
      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ ~s(id="users")
    end

    test "renders an action column header and cells when an action slot is given" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 1, name: "Alice"}],
          col: [
            %{__slot__: :col, label: "Name", inner_block: fn _, row -> row.name end}
          ],
          action: [
            %{__slot__: :action, inner_block: fn _, _row -> "Edit" end}
          ]
        })

      assert html =~ "Edit"
      assert html =~ "Actions"
      assert html =~ "sr-only"
    end

    test "omits the action column when no action slot" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 1, name: "Alice"}],
          col: [
            %{__slot__: :col, label: "Name", inner_block: fn _, row -> row.name end}
          ]
        })

      refute html =~ "sr-only"
    end

    test "wires phx-click and cursor class when row_click is provided" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 1, name: "Alice"}],
          row_click: fn row -> "clicked-#{row.id}" end,
          col: [
            %{__slot__: :col, label: "Name", inner_block: fn _, row -> row.name end}
          ]
        })

      assert html =~ "clicked-1"
      assert html =~ "hover:cursor-pointer"
    end

    test "applies row_id to each row when provided" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 7, name: "Alice"}],
          row_id: fn row -> "row-#{row.id}" end,
          col: [
            %{__slot__: :col, label: "Name", inner_block: fn _, row -> row.name end}
          ]
        })

      assert html =~ ~s(id="row-7")
    end
  end

  # ==========================================================================
  # list/1
  # ==========================================================================

  describe "list/1" do
    test "renders one row per item with title and content" do
      html =
        render_component(&CoreComponents.list/1, %{
          item: [
            %{__slot__: :item, title: "Title", inner_block: fn _, _ -> "My Post" end},
            %{__slot__: :item, title: "Views", inner_block: fn _, _ -> "42" end}
          ]
        })

      assert html =~ "<ul"
      assert html =~ "Title"
      assert html =~ "My Post"
      assert html =~ "Views"
      assert html =~ "42"
      assert html =~ "font-bold"
    end
  end

  # ==========================================================================
  # icon/1
  # ==========================================================================

  describe "icon/1" do
    test "renders a span with the hero name and default size class" do
      html = render_component(&CoreComponents.icon/1, %{name: "hero-x-mark"})

      assert html =~ "<span"
      assert html =~ "hero-x-mark"
      assert html =~ "size-4"
    end

    test "honors a custom class" do
      html =
        render_component(&CoreComponents.icon/1, %{
          name: "hero-arrow-path",
          class: "ml-1 size-3 animate-spin"
        })

      assert html =~ "hero-arrow-path"
      assert html =~ "animate-spin"
      assert html =~ "size-3"
    end
  end
end
