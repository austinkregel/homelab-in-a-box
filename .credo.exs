# Credo config for homelab-in-a-box.
# precommit uses --fail-level high to avoid failing on legacy design/refactor noise.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/priv/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          {Credo.Check.Design.DuplicatedCode, false},
          {Credo.Check.Refactor.Nesting, false},
          {Credo.Check.Readability.Specs, false}
        ]
      }
    }
  ]
}
