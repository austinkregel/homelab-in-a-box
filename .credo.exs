# Credo configuration.
#
# Only `extra:` is used for checks, which MERGES with Credo's default set rather
# than replacing it — so the default checks keep running untouched and this file
# stays a registration point rather than a second, drifting copy of the ruleset.
#
# Custom checks live in `credo_checks/` rather than `lib/` on purpose: they call
# `use Credo.Check`, and credo is `only: [:dev, :test], runtime: false`, so a
# check under `lib/` would fail the MIX_ENV=prod release build. `requires:`
# loads them at analysis time, when credo is available.
%{
  configs: [
    %{
      name: "default",
      files: %{
        # `credo_checks/` is tooling, not application code, and is deliberately
        # not linted — it is loaded via `requires` below, not compiled by mix.
        included: ["lib/", "test/"],
        excluded: []
      },
      requires: ["./credo_checks/"],
      strict: true,
      checks: %{
        extra: [
          {Homelab.Credo.Check.EarlyReturn, []}
        ]
      }
    }
  ]
}
