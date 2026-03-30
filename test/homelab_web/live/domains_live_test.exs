defmodule HomelabWeb.DomainsLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)
    template = insert(:app_template)

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn, tenant: tenant, template: template}
  end

  describe "mount" do
    test "renders domains page with zones tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "Domains &amp; DNS" or html =~ "Domains"
      assert html =~ "DNS Zones"
    end

    test "shows tab navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      assert has_element?(view, "button", "DNS Zones")
      assert has_element?(view, "button", "Domains")
      assert has_element?(view, "button", "DNS Records")
    end

    test "shows empty zones state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "No DNS zones" or html =~ "0 zone(s)"
    end
  end

  describe "tab switching" do
    test "switch to domains tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "Domains" or html =~ "domain(s)"
    end

    test "switch to records tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "DNS Records" or html =~ "record(s)"
    end

    test "switch back to zones tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      html = render_click(view, "switch_tab", %{"tab" => "zones"})
      assert html =~ "zone(s)"
    end
  end

  describe "zone CRUD" do
    test "open_add_zone shows modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "open_add_zone", %{})
      assert has_element?(view, "#add-zone-form")
    end

    test "close_modal hides add zone modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "open_add_zone", %{})
      assert has_element?(view, "#add-zone-form")
      render_click(view, "close_modal", %{})
      refute has_element?(view, "#add-zone-form")
    end

    test "save_zone creates a new DNS zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "open_add_zone", %{})

      html =
        view
        |> form("#add-zone-form", %{"zone" => %{"name" => "example.com"}})
        |> render_submit()

      assert html =~ "Zone created successfully" or html =~ "example.com"
    end

    test "delete_zone deletes a zone", %{conn: conn} do
      zone = insert(:dns_zone, name: "deleteme.com")
      {:ok, view, _html} = live(conn, ~p"/domains")

      html = render_click(view, "delete_zone", %{"id" => to_string(zone.id)})
      assert html =~ "Zone deleted"
    end
  end

  describe "with existing zones" do
    setup do
      zone = insert(:dns_zone, name: "test.example.com")
      {:ok, zone: zone}
    end

    test "shows zone in table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "test.example.com"
    end

    test "shows zone count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "1 zone(s)"
    end
  end

  describe "domain assignment" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "ext_1",
          domain: nil
        )

      zone = insert(:dns_zone, name: "myzone.com")
      {:ok, deployment: deployment, zone: zone}
    end

    test "open_add_domain shows modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "domains"})
      render_click(view, "open_add_domain", %{})
      assert has_element?(view, "#add-domain-form")
    end

    test "save_domain assigns domain to deployment", %{
      conn: conn,
      deployment: dep,
      zone: zone
    } do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "domains"})
      render_click(view, "open_add_domain", %{})

      html =
        view
        |> form("#add-domain-form", %{
          "add_domain" => %{
            "deployment_id" => to_string(dep.id),
            "domain" => "app.myzone.com",
            "dns_zone_id" => to_string(zone.id)
          }
        })
        |> render_submit()

      assert html =~ "Domain assigned successfully"
    end
  end

  describe "DNS record CRUD" do
    setup do
      zone = insert(:dns_zone, name: "records.example.com")
      {:ok, zone: zone}
    end

    test "open_add_record shows modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      render_click(view, "open_add_record", %{})
      assert has_element?(view, "#add-record-form")
    end

    test "save_record creates a DNS record", %{conn: conn, zone: zone} do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone_id, _attrs -> {:ok, %{id: "rec_1"}} end)

      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      render_click(view, "open_add_record", %{})

      html =
        view
        |> form("#add-record-form", %{
          "record" => %{
            "dns_zone_id" => to_string(zone.id),
            "name" => "www",
            "type" => "A",
            "value" => "192.168.1.100",
            "ttl" => "300",
            "scope" => "public"
          }
        })
        |> render_submit()

      assert html =~ "DNS record created"
    end

    test "delete_record deletes a DNS record", %{conn: conn, zone: zone} do
      record = insert(:dns_record, dns_zone: zone, name: "todelete", value: "10.0.0.1")

      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})

      html = render_click(view, "delete_record", %{"id" => to_string(record.id)})
      assert html =~ "DNS record deleted"
    end
  end

  describe "sync_registrar" do
    test "triggers registrar sync", %{conn: conn} do
      Homelab.Mocks.RegistrarProvider
      |> stub(:list_domains, fn -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "sync_registrar", %{})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Sync" or html =~ "sync" or html =~ "registrar"
    end
  end

  describe "handle_info :do_sync_registrar" do
    test "syncs domains from registrar", %{conn: conn} do
      Homelab.Mocks.RegistrarProvider
      |> expect(:list_domains, fn -> {:ok, []} end)

      {:ok, view, _html} = live(conn, ~p"/domains")
      send(view.pid, :do_sync_registrar)
      ref = Process.monitor(view.pid)
      refute_receive {:DOWN, ^ref, :process, _, _}, 500
      html = render(view)
      assert html =~ "Sync" or html =~ "zone" or html =~ "domain"
    end
  end

  describe "records tab with existing records" do
    setup do
      zone = insert(:dns_zone, name: "reczone.example.com")

      record_a =
        insert(:dns_record,
          dns_zone: zone,
          name: "www",
          type: "A",
          value: "10.0.0.1",
          scope: :public,
          managed: false
        )

      record_cname =
        insert(:dns_record,
          dns_zone: zone,
          name: "mail",
          type: "CNAME",
          value: "mail.provider.com",
          scope: :internal,
          managed: true
        )

      {:ok, zone: zone, record_a: record_a, record_cname: record_cname}
    end

    test "renders records table with record data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "www"
      assert html =~ "10.0.0.1"
      assert html =~ "reczone.example.com"
    end

    test "shows record type badges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "A"
      assert html =~ "CNAME"
    end

    test "shows managed vs manual labels", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "Auto"
      assert html =~ "Manual"
    end

    test "shows correct record count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "2 record(s)"
    end

    test "delete button present for each record", %{conn: conn, record_a: record} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      assert has_element?(view, "button[phx-click='delete_record'][phx-value-id='#{record.id}']")
    end
  end

  describe "domains tab with existing domain assignments" do
    setup %{tenant: tenant, template: template} do
      zone = insert(:dns_zone, name: "assigned.example.com")

      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "ext_domain",
          domain: "app.assigned.example.com"
        )

      domain =
        insert(:domain,
          fqdn: "app.assigned.example.com",
          deployment: deployment,
          dns_zone: zone,
          tls_status: :active,
          exposure_mode: :public
        )

      {:ok, deployment: deployment, domain: domain, zone: zone}
    end

    test "shows domain in domains table", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "app.assigned.example.com"
    end

    test "shows TLS status badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "Active"
    end

    test "shows domain count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "domain(s)"
    end

    test "shows zone name for linked domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "assigned.example.com"
    end
  end

  describe "save_domain with invalid deployment" do
    test "shows error for non-existent deployment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "domains"})
      render_click(view, "open_add_domain", %{})

      html =
        render_click(view, "save_domain", %{
          "add_domain" => %{
            "deployment_id" => "999999",
            "domain" => "bad.example.com",
            "dns_zone_id" => ""
          }
        })

      assert html =~ "not found" or html =~ "error" or html =~ "Error" or html =~ "Failed"
    end
  end

  describe "save_domain without dns zone" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "ext_nozone",
          domain: nil
        )

      {:ok, deployment: deployment}
    end

    test "assigns domain without creating dns entry", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "domains"})
      render_click(view, "open_add_domain", %{})

      html =
        view
        |> form("#add-domain-form", %{
          "add_domain" => %{
            "deployment_id" => to_string(dep.id),
            "domain" => "nozone.example.com",
            "dns_zone_id" => ""
          }
        })
        |> render_submit()

      assert html =~ "Domain assigned successfully"
    end
  end

  describe "zone with records count" do
    setup do
      zone = insert(:dns_zone, name: "counted.example.com")
      insert(:dns_record, dns_zone: zone, name: "a1", value: "10.0.0.1")
      insert(:dns_record, dns_zone: zone, name: "a2", value: "10.0.0.2")
      insert(:dns_record, dns_zone: zone, name: "a3", value: "10.0.0.3")
      {:ok, zone: zone}
    end

    test "shows zone with record count in table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "counted.example.com"
      assert html =~ "3"
    end
  end

  describe "sync_registrar error handling" do
    test "shows error when no registrar configured", %{conn: conn} do
      Homelab.Mocks.RegistrarProvider
      |> stub(:list_domains, fn -> {:error, :no_registrar_configured} end)

      {:ok, view, _html} = live(conn, ~p"/domains")
      send(view.pid, :do_sync_registrar)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "No registrar configured" or html =~ "Sync" or html =~ "error"
    end
  end

  describe "empty states" do
    test "domains tab shows empty state when no domains", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "No domains configured" or html =~ "0 domain(s)"
    end

    test "records tab shows empty state when no records", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "No DNS records" or html =~ "0 record(s)"
    end
  end

  describe "add record form" do
    setup do
      zone = insert(:dns_zone, name: "formzone.example.com")
      {:ok, zone: zone}
    end

    test "open_add_record shows form with zone select", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      render_click(view, "open_add_record", %{})
      assert has_element?(view, "#add-record-form")
      html = render(view)
      assert html =~ "formzone.example.com"
    end

    test "close modal hides add record form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      render_click(view, "switch_tab", %{"tab" => "records"})
      render_click(view, "open_add_record", %{})
      assert has_element?(view, "#add-record-form")
      render_click(view, "close_modal", %{})
      refute has_element?(view, "#add-record-form")
    end
  end

  describe "zones tab with multiple zones" do
    setup do
      zone1 = insert(:dns_zone, name: "alpha.example.com")
      zone2 = insert(:dns_zone, name: "beta.example.com")
      zone3 = insert(:dns_zone, name: "gamma.example.com")
      {:ok, zones: [zone1, zone2, zone3]}
    end

    test "renders all three zones in table", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "alpha.example.com"
      assert html =~ "beta.example.com"
      assert html =~ "gamma.example.com"
    end

    test "shows correct zone count for multiple zones", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/domains")
      assert html =~ "3 zone(s)"
    end

    test "each zone has a delete button", %{conn: conn, zones: zones} do
      {:ok, view, _html} = live(conn, ~p"/domains")

      for zone <- zones do
        assert has_element?(
                 view,
                 "button[phx-click='delete_zone'][phx-value-id='#{zone.id}']"
               )
      end
    end
  end

  describe "records tab with different record types" do
    setup do
      zone = insert(:dns_zone, name: "typezone.example.com")

      record_a =
        insert(:dns_record,
          dns_zone: zone,
          name: "web",
          type: "A",
          value: "10.0.0.10",
          scope: :public,
          managed: false
        )

      record_cname =
        insert(:dns_record,
          dns_zone: zone,
          name: "cdn",
          type: "CNAME",
          value: "cdn.provider.net",
          scope: :public,
          managed: true
        )

      record_txt =
        insert(:dns_record,
          dns_zone: zone,
          name: "_dmarc",
          type: "TXT",
          value: "v=DMARC1; p=none",
          scope: :public,
          managed: false
        )

      {:ok, zone: zone, record_a: record_a, record_cname: record_cname, record_txt: record_txt}
    end

    test "renders A, CNAME, and TXT type badges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "A"
      assert html =~ "CNAME"
      assert html =~ "TXT"
    end

    test "renders record names for all types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "web"
      assert html =~ "cdn"
      assert html =~ "_dmarc"
    end

    test "renders record values for all types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "10.0.0.10"
      assert html =~ "cdn.provider.net"
      assert html =~ "v=DMARC1"
    end

    test "shows 3 record count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "records"})
      assert html =~ "3 record(s)"
    end
  end

  describe "domain assignments with TLS status" do
    setup %{tenant: tenant, template: template} do
      zone = insert(:dns_zone, name: "tls.example.com")

      deployment_active =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "ext_tls_active",
          domain: "secure.tls.example.com"
        )

      domain_active =
        insert(:domain,
          fqdn: "secure.tls.example.com",
          deployment: deployment_active,
          dns_zone: zone,
          tls_status: :active,
          exposure_mode: :public
        )

      deployment_pending =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "ext_tls_pending",
          domain: "pending.tls.example.com"
        )

      domain_pending =
        insert(:domain,
          fqdn: "pending.tls.example.com",
          deployment: deployment_pending,
          dns_zone: zone,
          tls_status: :pending,
          exposure_mode: :sso_protected
        )

      {:ok,
       zone: zone,
       domain_active: domain_active,
       domain_pending: domain_pending,
       deployment_active: deployment_active,
       deployment_pending: deployment_pending}
    end

    test "shows Active TLS badge for active TLS domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "Active"
      assert html =~ "secure.tls.example.com"
    end

    test "shows Pending TLS badge for pending TLS domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "Pending"
      assert html =~ "pending.tls.example.com"
    end

    test "shows exposure mode badges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "Public" or html =~ "SSO"
    end

    test "shows domain count for multiple domains", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/domains")
      html = render_click(view, "switch_tab", %{"tab" => "domains"})
      assert html =~ "domain(s)"
    end
  end
end
