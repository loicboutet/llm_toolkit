# frozen_string_literal: true

require "test_helper"

# Test to verify that Ruby interpolation syntax #{...} is NOT escaped to \#{...}
# when file contents are sent through the tool result pipeline to the LLM.
#
# Bug description:
# When a file containing Ruby code with interpolation syntax like:
#   puts "Hello, #{name}!"
# is read via str_replace_editor and sent to the LLM, the content arrives as:
#   puts "Hello, \#{name}!"
# This causes the LLM to make mistakes when editing Ruby files.
#
class HashInterpolationEscapeTest < ActiveSupport::TestCase
  # Sample Ruby code with interpolation - this should NEVER be escaped
  RUBY_CODE_WITH_INTERPOLATION = <<~RUBY
    class Example
      def greet(name)
        puts "Hello, \#{name}!"
        Rails.logger.info("User \#{name} logged in at \#{Time.now}")
      end
      
      def format_message(count)
        "You have \#{count} new messages"
      end
    end
  RUBY

  test "ruby interpolation syntax should contain hash symbol" do
    # Verify our test data is correct
    assert RUBY_CODE_WITH_INTERPOLATION.include?('#{'), 
      "Test data should contain unescaped \#{...} syntax"
    
    # It should NOT contain escaped version
    refute RUBY_CODE_WITH_INTERPOLATION.include?('\#{'),
      "Test data should NOT contain escaped \\#\{...} syntax"
  end

  test "tool_result content preserves ruby interpolation syntax" do
    skip "Requires full Rails environment with database"
    
    # Create a tool result with Ruby code content
    # This simulates what happens when str_replace_editor reads a Ruby file
    conversation = create_test_conversation
    message = conversation.messages.create!(role: 'assistant', content: 'Test')
    tool_use = message.tool_uses.create!(
      name: 'str_replace_editor',
      tool_use_id: SecureRandom.uuid,
      input: { command: 'view', path: '/test/file.rb' }
    )
    
    tool_result = tool_use.create_tool_result!(
      message: message,
      content: RUBY_CODE_WITH_INTERPOLATION,
      is_error: false
    )
    
    # Reload from database to ensure we test what's actually stored
    tool_result.reload
    
    # The content should preserve the interpolation syntax
    assert tool_result.content.include?('#{name}'),
      "Stored content should contain unescaped \#{name}"
    refute tool_result.content.include?('\#{name}'),
      "Stored content should NOT contain escaped \\#\{name}"
  end

  test "conversation history preserves ruby interpolation in tool results" do
    skip "Requires full Rails environment with database"
    
    conversation = create_test_conversation
    message = conversation.messages.create!(role: 'assistant', content: 'Reading file')
    tool_use = message.tool_uses.create!(
      name: 'str_replace_editor',
      tool_use_id: SecureRandom.uuid,
      input: { command: 'view', path: '/test/file.rb' }
    )
    
    tool_use.create_tool_result!(
      message: message,
      content: RUBY_CODE_WITH_INTERPOLATION,
      is_error: false
    )
    
    # Get the conversation history as it would be sent to the LLM
    history = conversation.history
    
    # Find the tool result message in history
    tool_result_message = history.find { |m| m[:role] == 'tool' || (m[:content].is_a?(Array) && m[:content].any? { |c| c[:type] == 'tool_result' }) }
    
    assert tool_result_message, "History should contain a tool result message"
    
    # Extract the content from the tool result
    content = extract_tool_result_content(tool_result_message)
    
    # Verify the interpolation syntax is preserved
    assert content.include?('#{name}'),
      "History content should contain unescaped \#{name}, got: #{content[0..200]}"
    refute content.include?('\#{name}'),
      "History content should NOT contain escaped \\#\{name}"
  end

  test "JSON serialization preserves ruby interpolation syntax" do
    # Test that JSON round-trip doesn't escape the hash symbol
    data = {
      content: RUBY_CODE_WITH_INTERPOLATION,
      message: 'Test message with #{interpolation}'
    }
    
    json_string = data.to_json
    parsed = JSON.parse(json_string)
    
    # After round-trip, the content should be unchanged
    assert_equal RUBY_CODE_WITH_INTERPOLATION, parsed['content'],
      "JSON round-trip should preserve \#{...} syntax"
    
    # The parsed message should also be unchanged
    assert parsed['message'].include?('#{interpolation}'),
      "Parsed JSON should contain \#{interpolation}"
  end

  test "string inspection does escape hash but to_s does not" do
    # This documents Ruby behavior that could cause the bug
    str = 'Hello #{name}'
    
    # .inspect escapes the hash symbol
    inspected = str.inspect
    assert inspected.include?('\#{'), 
      ".inspect should escape \#{, got: #{inspected}"
    
    # .to_s does NOT escape
    stringified = str.to_s
    refute stringified.include?('\#{'),
      ".to_s should NOT escape \#{, got: #{stringified}"
    
    # This is likely where the bug comes from - using .inspect instead of .to_s
    # somewhere in the pipeline
  end

  test "detecting the escape bug pattern" do
    # Helper method to detect if content has the bug
    has_escape_bug = ->(content) { content.include?('\#{') }
    
    correct_content = 'puts "Hello, #{name}!"'
    buggy_content = 'puts "Hello, \#{name}!"'
    
    refute has_escape_bug.call(correct_content), 
      "Correct content should NOT have escape bug"
    assert has_escape_bug.call(buggy_content), 
      "Buggy content SHOULD be detected as having escape bug"
  end

  private

  def create_test_conversation
    # Create a minimal conversation for testing
    user = User.first || User.create!(email: 'test@example.com', password: 'password123')
    LlmToolkit::Conversation.create!(
      conversable: user,
      agent_type: :coder,
      status: :resting
    )
  end

  def extract_tool_result_content(message)
    if message[:content].is_a?(String)
      message[:content]
    elsif message[:content].is_a?(Array)
      tool_result = message[:content].find { |c| c[:type] == 'tool_result' }
      tool_result&.dig(:content) || ''
    else
      ''
    end
  end
end
