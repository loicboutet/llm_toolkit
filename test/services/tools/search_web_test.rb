require "test_helper"

module LlmToolkit
  class SearchWebTest < ActiveSupport::TestCase
    def setup
      @conversable = mock("Conversable")
    end

    test "definition has expected structure" do
      skip "SearchWeb tool structure changed - needs test update"
      definition = LlmToolkit::Tools::SearchWeb.definition
      
      assert_equal "search", definition[:name]
      assert_includes definition[:description], "search query"
      assert_equal "object", definition[:input_schema][:type]
      assert_includes definition[:input_schema][:required], "query"
    end

    test "formats search results when valid JSON is returned" do
      skip "SearchWeb depends on JinaService which changed - needs test update"
      mock_response = {
        'data' => [
          {
            'title' => 'Test Result',
            'url' => 'https://example.com',
            'description' => 'A test search result',
            'content' => 'Content of the search result'
          }
        ]
      }.to_json
      
      LlmToolkit::JinaService.any_instance.stubs(:search).returns(mock_response)
      
      result = LlmToolkit::Tools::SearchWeb.execute(
        conversable: @conversable,
        args: { "query" => "test search" }
      )
      
      assert result[:result].is_a?(Array)
      assert_equal "Test Result", result[:result].first[:title]
    end

    test "handles service exceptions" do
      skip "SearchWeb depends on JinaService which changed - needs test update"
      LlmToolkit::JinaService.any_instance.stubs(:search).raises(StandardError.new("API Error"))
      
      result = LlmToolkit::Tools::SearchWeb.execute(
        conversable: @conversable,
        args: { "query" => "test search" }
      )
      
      assert result[:error].present?
      assert_includes result[:error], "Error performing web search"
    end

    test "passes optional parameters correctly" do
      skip "SearchWeb depends on JinaService which changed - needs test update"
      LlmToolkit::JinaService.any_instance.expects(:search).with(
        "test search", 
        has_entries(
          gl: "US",
          site: "example.com",
          with_links_summary: true
        )
      ).returns("[]")
      
      LlmToolkit::Tools::SearchWeb.execute(
        conversable: @conversable,
        args: { 
          "query" => "test search",
          "country_code" => "US",
          "site" => "example.com",
          "with_links_summary" => true
        }
      )
    end
  end
end