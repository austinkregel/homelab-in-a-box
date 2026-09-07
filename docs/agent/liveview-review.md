# LiveView review checklist

Project-specific items beyond generic Phoenix rules in `AGENTS.md`.

## Layout and auth

- Templates start with `<Layouts.app flash={@flash} ...>`
- Pass `current_user` where needed — this app uses custom hooks, **not** `current_scope`
- Never call `<.flash_group>` outside `layouts.ex`

## Collections

- Use **LiveView streams** for lists (`stream/3`, `phx-update="stream"`, `@streams.name`)
- Re-stream items when assigns inside streamed rows change
- Track empty state with a separate assign or `only:block` CSS pattern

## Forms

- `to_form/2` in LiveView; `<.form for={@form}>` in templates
- Use `<.input field={@form[:field]}>` — never expose raw changesets in templates
- Unique DOM ids on forms and key controls (`id="deployment-form"`)

## Icons and styling

- `<.icon name="hero-...">` only — no Heroicons modules
- Tailwind class lists use `[...]` syntax with conditional entries

## Navigation

- `<.link navigate={...}>` / `push_navigate` — not deprecated `live_redirect`

## Tests

- `Phoenix.LiveViewTest` + `has_element?(view, "#id")`
- No Floki `fl-contains` selectors — use `element("selector", "text")`
- No `Process.sleep/1` — use `Process.monitor/1` or `_ = :sys.get_state(pid)`

## HEEx

- No `else if` — use `cond` or `case`
- Attribute interpolation: `{...}`; body blocks: `<%= ... %>`
- `phx-no-curly-interpolation` for literal `{` `}` in code samples
