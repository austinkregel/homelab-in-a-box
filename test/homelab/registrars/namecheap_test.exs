defmodule Homelab.Registrars.NamecheapTest do
  use ExUnit.Case, async: true

  alias Homelab.Registrars.Namecheap

  @domains_response """
  <?xml version="1.0" encoding="UTF-8"?>
  <ApiResponse xmlns="http://api.namecheap.com/xml.response" Status="OK">
    <Errors />
    <RequestedCommand>namecheap.domains.getList</RequestedCommand>
    <CommandResponse Type="namecheap.domains.getList">
      <DomainGetListResult>
        <Domain ID="127" Name="example.com" User="testuser" Created="02/15/2016" Expires="02/15/2028" IsExpired="false" IsLocked="false" AutoRenew="true" WhoisGuard="ENABLED" IsPremium="false" IsOurDNS="true"/>
        <Domain ID="381" Name="mysite.org" User="testuser" Created="04/28/2016" Expires="04/28/2025" IsExpired="true" IsLocked="false" AutoRenew="false" WhoisGuard="NOTPRESENT" IsPremium="false" IsOurDNS="false"/>
      </DomainGetListResult>
      <Paging>
        <TotalItems>2</TotalItems>
        <CurrentPage>1</CurrentPage>
        <PageSize>100</PageSize>
      </Paging>
    </CommandResponse>
    <Server>SERVER-NAME</Server>
    <GMTTimeDifference>+5</GMTTimeDifference>
    <ExecutionTime>0.078</ExecutionTime>
  </ApiResponse>
  """

  @nameservers_response """
  <?xml version="1.0" encoding="UTF-8"?>
  <ApiResponse xmlns="http://api.namecheap.com/xml.response" Status="OK">
    <Errors />
    <RequestedCommand>namecheap.domains.dns.getList</RequestedCommand>
    <CommandResponse Type="namecheap.domains.dns.getList">
      <DomainDNSGetListResult Domain="example.com" IsUsingOurDNS="true">
        <Nameserver>dns1.registrar-servers.com</Nameserver>
        <Nameserver>dns2.registrar-servers.com</Nameserver>
      </DomainDNSGetListResult>
    </CommandResponse>
    <Server>SERVER-NAME</Server>
    <GMTTimeDifference>+5</GMTTimeDifference>
    <ExecutionTime>0.032</ExecutionTime>
  </ApiResponse>
  """

  @error_response """
  <?xml version="1.0" encoding="UTF-8"?>
  <ApiResponse xmlns="http://api.namecheap.com/xml.response" Status="ERROR">
    <Errors>
      <Error Number="2019166">Domain not found</Error>
    </Errors>
    <RequestedCommand>namecheap.domains.dns.getList</RequestedCommand>
    <CommandResponse />
    <Server>SERVER-NAME</Server>
    <GMTTimeDifference>+5</GMTTimeDifference>
    <ExecutionTime>0.010</ExecutionTime>
  </ApiResponse>
  """

  @paginated_page1 """
  <?xml version="1.0" encoding="UTF-8"?>
  <ApiResponse xmlns="http://api.namecheap.com/xml.response" Status="OK">
    <Errors />
    <RequestedCommand>namecheap.domains.getList</RequestedCommand>
    <CommandResponse Type="namecheap.domains.getList">
      <DomainGetListResult>
        <Domain ID="1" Name="first.com" User="testuser" Created="01/01/2020" Expires="01/01/2030" IsExpired="false" IsLocked="false" AutoRenew="true" WhoisGuard="ENABLED" IsPremium="false" IsOurDNS="true"/>
      </DomainGetListResult>
      <Paging>
        <TotalItems>2</TotalItems>
        <CurrentPage>1</CurrentPage>
        <PageSize>1</PageSize>
      </Paging>
    </CommandResponse>
  </ApiResponse>
  """

  @paginated_page2 """
  <?xml version="1.0" encoding="UTF-8"?>
  <ApiResponse xmlns="http://api.namecheap.com/xml.response" Status="OK">
    <Errors />
    <RequestedCommand>namecheap.domains.getList</RequestedCommand>
    <CommandResponse Type="namecheap.domains.getList">
      <DomainGetListResult>
        <Domain ID="2" Name="second.com" User="testuser" Created="02/01/2020" Expires="02/01/2030" IsExpired="false" IsLocked="false" AutoRenew="false" WhoisGuard="NOTPRESENT" IsPremium="false" IsOurDNS="true"/>
      </DomainGetListResult>
      <Paging>
        <TotalItems>2</TotalItems>
        <CurrentPage>2</CurrentPage>
        <PageSize>1</PageSize>
      </Paging>
    </CommandResponse>
  </ApiResponse>
  """

  describe "parse_xml/1" do
    test "parses a successful domains response" do
      assert {:ok, _doc} = Namecheap.parse_xml(@domains_response)
    end

    test "parses a successful nameservers response" do
      assert {:ok, _doc} = Namecheap.parse_xml(@nameservers_response)
    end

    test "returns error tuple for API error responses" do
      assert {:error, {:api_errors, errors}} = Namecheap.parse_xml(@error_response)
      assert is_list(errors)
      assert Enum.any?(errors, &String.contains?(&1, "Domain not found"))
    end

    test "returns error for invalid XML" do
      assert {:error, {:xml_parse_error, _reason}} = Namecheap.parse_xml("not xml at all")
    end

    test "returns error for empty string" do
      assert {:error, _} = Namecheap.parse_xml("")
    end
  end

  describe "parse_xml/1 domain extraction" do
    test "extracts domain attributes from parsed XML" do
      {:ok, doc} = Namecheap.parse_xml(@domains_response)

      domains =
        :xmerl_xpath.string(~c"//Domain", doc)
        |> Enum.map(fn elem ->
          attrs = elem(elem, 7)

          name =
            Enum.find(attrs, fn a -> elem(a, 1) == :Name end)
            |> then(fn a -> elem(a, 8) |> to_string() end)

          id =
            Enum.find(attrs, fn a -> elem(a, 1) == :ID end)
            |> then(fn a -> elem(a, 8) |> to_string() end)

          %{name: name, id: id}
        end)

      assert length(domains) == 2
      assert Enum.at(domains, 0).name == "example.com"
      assert Enum.at(domains, 0).id == "127"
      assert Enum.at(domains, 1).name == "mysite.org"
      assert Enum.at(domains, 1).id == "381"
    end
  end

  describe "parse_xml/1 nameserver extraction" do
    test "extracts nameserver values from parsed XML" do
      {:ok, doc} = Namecheap.parse_xml(@nameservers_response)

      nameservers =
        :xmerl_xpath.string(~c"//Nameserver", doc)
        |> Enum.map(fn elem ->
          elem(elem, 8)
          |> Enum.filter(fn node -> Record.is_record(node, :xmlText) end)
          |> Enum.map(fn text -> elem(text, 4) |> to_string() end)
          |> Enum.join()
          |> String.trim()
        end)

      assert nameservers == ["dns1.registrar-servers.com", "dns2.registrar-servers.com"]
    end
  end

  describe "parse_xml/1 pagination" do
    test "page 1 paging values indicate more pages" do
      {:ok, doc} = Namecheap.parse_xml(@paginated_page1)

      total = paging_value(doc, "TotalItems")
      current = paging_value(doc, "CurrentPage")
      page_size = paging_value(doc, "PageSize")

      assert total == 2
      assert current == 1
      assert page_size == 1
      assert current * page_size < total
    end

    test "page 2 paging values indicate no more pages" do
      {:ok, doc} = Namecheap.parse_xml(@paginated_page2)

      total = paging_value(doc, "TotalItems")
      current = paging_value(doc, "CurrentPage")
      page_size = paging_value(doc, "PageSize")

      assert total == 2
      assert current == 2
      assert page_size == 1
      refute current * page_size < total
    end
  end

  describe "driver_id/0" do
    test "returns namecheap" do
      assert Namecheap.driver_id() == "namecheap"
    end
  end

  describe "display_name/0" do
    test "returns Namecheap" do
      assert Namecheap.display_name() == "Namecheap"
    end
  end

  defp paging_value(doc, tag_name) do
    case :xmerl_xpath.string(~c"//Paging/#{String.to_charlist(tag_name)}", doc) do
      [elem | _] ->
        content = elem(elem, 8)

        text =
          content
          |> Enum.filter(fn node -> Record.is_record(node, :xmlText) end)
          |> Enum.map(fn text -> elem(text, 4) |> to_string() end)
          |> Enum.join()
          |> String.trim()

        case Integer.parse(text) do
          {n, _} -> n
          :error -> nil
        end

      [] ->
        nil
    end
  end
end
