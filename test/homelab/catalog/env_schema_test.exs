defmodule Homelab.Catalog.EnvSchemaTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.EnvSchema

  defp changeset(env_schema) do
    Ecto.Changeset.cast({%{env_schema: %{}}, %{env_schema: :map}}, %{env_schema: env_schema}, [
      :env_schema
    ])
  end

  describe "parse/1" do
    test "keeps the settings it recognizes and drops the rest" do
      parsed =
        EnvSchema.parse(%{
          "VPN_TYPE" => %{
            "label" => "Tunnel protocol",
            "enum" => ["wireguard", "openvpn"],
            "required" => true,
            "colour" => "blue"
          }
        })

      assert parsed == %{
               "VPN_TYPE" => %{
                 "label" => "Tunnel protocol",
                 "enum" => ["wireguard", "openvpn"],
                 "required" => true
               }
             }
    end

    test "normalizes a single condition value to a list" do
      parsed = EnvSchema.parse(%{"K" => %{"required_when" => %{"VPN_TYPE" => "openvpn"}}})

      assert parsed == %{"K" => %{"required_when" => %{"VPN_TYPE" => ["openvpn"]}}}
    end

    test "drops a condition that normalizes to nothing rather than leaving it empty" do
      # An empty condition map satisfies Enum.all?/2, which would make the variable
      # unconditionally required.
      assert EnvSchema.parse(%{"K" => %{"required_when" => %{"VPN_TYPE" => []}}}) == %{"K" => %{}}
      assert EnvSchema.required_keys(%{"K" => %{"required_when" => %{}}}, %{}) == []
    end

    test "anything that is not a map of name to descriptor is dropped" do
      assert EnvSchema.parse(nil) == %{}
      assert EnvSchema.parse("VPN_TYPE") == %{}
      assert EnvSchema.parse(%{"VPN_TYPE" => "wireguard"}) == %{}
    end
  end

  describe "required_keys/2" do
    @gluetun %{
      "VPN_TYPE" => %{"enum" => ["wireguard", "openvpn"], "required" => true},
      "WIREGUARD_PRIVATE_KEY" => %{
        "secret" => true,
        "required_when" => %{"VPN_TYPE" => "wireguard"}
      },
      "OPENVPN_USER" => %{"required_when" => %{"VPN_TYPE" => "openvpn"}},
      "SERVER_COUNTRIES" => %{}
    }

    test "an empty schema demands nothing" do
      assert EnvSchema.required_keys(%{}, %{"VPN_TYPE" => "openvpn"}) == []
      assert EnvSchema.required_keys(nil, %{}) == []
    end

    test "only the selected mode's keys are demanded" do
      assert EnvSchema.required_keys(@gluetun, %{"VPN_TYPE" => "wireguard"}) ==
               ["VPN_TYPE", "WIREGUARD_PRIVATE_KEY"]

      assert EnvSchema.required_keys(@gluetun, %{"VPN_TYPE" => "openvpn"}) ==
               ["OPENVPN_USER", "VPN_TYPE"]
    end

    test "a value outside the enum selects no branch" do
      assert EnvSchema.required_keys(@gluetun, %{"VPN_TYPE" => "openvpm"}) == ["VPN_TYPE"]
    end

    test "every condition entry must match" do
      schema = %{
        "PROVIDER" => %{},
        "MODE" => %{},
        "K" => %{"required_when" => %{"MODE" => "openvpn", "PROVIDER" => "custom"}}
      }

      assert "K" in EnvSchema.required_keys(schema, %{"MODE" => "openvpn", "PROVIDER" => "custom"})

      refute "K" in EnvSchema.required_keys(schema, %{
               "MODE" => "openvpn",
               "PROVIDER" => "mullvad"
             })
    end

    test "a list of accepted values matches any of them" do
      schema = %{"MODE" => %{}, "K" => %{"required_when" => %{"MODE" => ["a", "b"]}}}

      assert "K" in EnvSchema.required_keys(schema, %{"MODE" => "b"})
      refute "K" in EnvSchema.required_keys(schema, %{"MODE" => "c"})
    end
  end

  describe "field metadata" do
    test "reports the enum and the secret flag" do
      schema = %{
        "VPN_TYPE" => %{"enum" => ["wireguard", "openvpn"]},
        "WIREGUARD_PRIVATE_KEY" => %{"secret" => true}
      }

      assert EnvSchema.enum(schema, "VPN_TYPE") == ["wireguard", "openvpn"]
      assert EnvSchema.enum(schema, "WIREGUARD_PRIVATE_KEY") == []
      assert EnvSchema.enum(schema, "NOT_DESCRIBED") == []

      assert EnvSchema.secret?(schema, "WIREGUARD_PRIVATE_KEY")
      refute EnvSchema.secret?(schema, "VPN_TYPE")
      refute EnvSchema.secret?(schema, "NOT_DESCRIBED")
    end
  end

  describe "validate_changeset/2" do
    test "accepts a well-formed schema" do
      cs =
        %{
          "VPN_TYPE" => %{"enum" => ["wireguard", "openvpn"], "required" => true},
          "OPENVPN_USER" => %{"required_when" => %{"VPN_TYPE" => "openvpn"}}
        }
        |> changeset()
        |> EnvSchema.validate_changeset(:env_schema)

      assert cs.valid?
    end

    test "an unchanged field is left alone" do
      cs =
        Ecto.Changeset.cast({%{env_schema: %{}}, %{env_schema: :map}}, %{}, [:env_schema])
        |> EnvSchema.validate_changeset(:env_schema)

      assert cs.valid?
    end

    test "rejects a misspelled setting rather than silently dropping it" do
      cs =
        %{"K" => %{"requred_when" => %{"VPN_TYPE" => "openvpn"}}}
        |> changeset()
        |> EnvSchema.validate_changeset(:env_schema)

      refute cs.valid?
      assert {"K has unrecognized settings: requred_when", _} = cs.errors[:env_schema]
    end

    test "rejects a condition on a variable the schema does not describe" do
      cs =
        %{"OPENVPN_USER" => %{"required_when" => %{"VPN_TYP" => "openvpn"}}}
        |> changeset()
        |> EnvSchema.validate_changeset(:env_schema)

      refute cs.valid?
      assert {message, _} = cs.errors[:env_schema]
      assert message =~ "conditional on undescribed variables: VPN_TYP"
    end

    test "rejects an empty or non-string enum" do
      refute %{"K" => %{"enum" => []}}
             |> changeset()
             |> EnvSchema.validate_changeset(:env_schema)
             |> Map.fetch!(:valid?)

      refute %{"K" => %{"enum" => ["a", 2]}}
             |> changeset()
             |> EnvSchema.validate_changeset(:env_schema)
             |> Map.fetch!(:valid?)
    end

    test "rejects an empty condition" do
      refute %{"K" => %{"required_when" => %{}}}
             |> changeset()
             |> EnvSchema.validate_changeset(:env_schema)
             |> Map.fetch!(:valid?)
    end

    test "rejects a descriptor that is not a map" do
      refute %{"K" => "required"}
             |> changeset()
             |> EnvSchema.validate_changeset(:env_schema)
             |> Map.fetch!(:valid?)
    end
  end
end
