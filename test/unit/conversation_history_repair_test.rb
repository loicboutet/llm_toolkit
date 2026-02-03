require 'test_helper'

# Test for the conversation history repair feature
# This tests the fix for the bug where a tool result is followed directly by a user message
# without an assistant response in between, which causes API errors (400 bad request)
class ConversationHistoryRepairTest < ActiveSupport::TestCase
  setup do
    # Create a tenant first
    @tenant = Tenant.find_or_create_by!(name: 'Test Tenant', subdomain: 'test-tenant-conv-repair')
    
    # Create or find a user with this tenant
    @user = User.find_by(email: 'test-conv-repair@example.com') || User.create!(
      email: 'test-conv-repair@example.com',
      password: 'password123',
      tenant: @tenant,
      role: 'user'
    )
    
    @provider = LlmToolkit::LlmProvider.find_or_create_by!(name: 'Test OpenRouter Provider') do |p|
      p.provider_type = 'openrouter'
      p.api_key = 'test_key'
    end
    
    @llm_model = LlmToolkit::LlmModel.find_or_create_by!(
      llm_provider: @provider,
      name: 'test-model'
    ) do |m|
      m.model_id = 'test/model'
    end
    
    # Make the user return this provider as default
    @user.define_singleton_method(:default_llm_provider) { @provider }
    
    # Store provider in instance var for the singleton method
    provider = @provider
    @user.define_singleton_method(:default_llm_provider) { provider }
  end

  teardown do
    # Clean up conversations created in tests
    LlmToolkit::Conversation.where(conversable: @user).destroy_all
  end

  test "history should detect tool->user sequence without assistant response and inject synthetic response" do
    conversation = create_conversation_with_orphan_tool_result

    # Get the history - this should now fix the invalid sequence
    history = conversation.history(llm_model: @llm_model)

    # Find the sequence: we should NOT have tool directly followed by user
    history.each_with_index do |msg, i|
      next if i == 0
      prev_msg = history[i - 1]
      
      if prev_msg[:role] == 'tool' && msg[:role] == 'user'
        flunk "Found invalid sequence: tool message at index #{i-1} directly followed by user message at index #{i}. " \
              "There should be an assistant message in between."
      end
    end

    # Verify that we have an assistant message after the tool result
    tool_indices = history.each_index.select { |i| history[i][:role] == 'tool' }
    tool_indices.each do |tool_idx|
      next_msg = history[tool_idx + 1]
      assert next_msg, "There should be a message after tool at index #{tool_idx}"
      
      # Next message should be either assistant or another tool (for parallel tool calls)
      assert ['assistant', 'tool'].include?(next_msg[:role]),
        "Message after tool should be assistant or tool, got: #{next_msg[:role]}"
    end
  end

  test "history should not modify valid sequences" do
    conversation = create_valid_conversation_with_tool_use

    history = conversation.history(llm_model: @llm_model)

    # Count messages by role
    roles = history.map { |m| m[:role] }
    
    # We should have: user, assistant (with tool_calls), tool, assistant, user
    assert_equal 'user', roles[0], "First message should be user"
    assert_equal 'assistant', roles[1], "Second message should be assistant"
    assert_equal 'tool', roles[2], "Third message should be tool"
    assert_equal 'assistant', roles[3], "Fourth message should be assistant"
    assert_equal 'user', roles[4], "Fifth message should be user"
  end

  test "history repair should handle multiple orphan tool results" do
    conversation = create_conversation_with_multiple_orphan_tools

    history = conversation.history(llm_model: @llm_model)

    # Verify no tool->user direct sequences
    history.each_with_index do |msg, i|
      next if i == 0
      prev_msg = history[i - 1]
      
      refute(prev_msg[:role] == 'tool' && msg[:role] == 'user',
        "Found invalid tool->user sequence at indices #{i-1}->#{i}")
    end
  end

  private

  def create_conversation_with_orphan_tool_result
    # This simulates the bug scenario:
    # 1. Assistant makes a tool call
    # 2. Tool result is received
    # 3. The followup call fails (error message created with is_error: true)
    # 4. User sends a new message
    # Result: tool -> user (invalid!)

    conversation = LlmToolkit::Conversation.create!(
      conversable: @user,
      agent_type: :coder,
      status: :resting
    )

    # Message 1: User asks something
    conversation.messages.create!(
      role: 'user',
      content: 'Please run a command'
    )

    # Message 2: Assistant with tool call
    assistant_msg = conversation.messages.create!(
      role: 'assistant',
      content: ''
    )

    # Create tool use
    tool_use = assistant_msg.tool_uses.create!(
      tool_use_id: 'toolu_test123',
      name: 'bash',
      input: { command: 'ls' }
    )

    # Create tool result
    tool_use.create_tool_result!(
      message: assistant_msg,
      content: 'file1.txt\nfile2.txt',
      is_error: false
    )

    # Message 3: Error message (this gets excluded by non_error scope!)
    conversation.messages.create!(
      role: 'assistant',
      content: 'Une erreur de format s\'est produite.',
      is_error: true,
      finish_reason: 'error'
    )

    # Message 4: User sends another message
    conversation.messages.create!(
      role: 'user',
      content: 'keep going'
    )

    conversation
  end

  def create_valid_conversation_with_tool_use
    conversation = LlmToolkit::Conversation.create!(
      conversable: @user,
      agent_type: :coder,
      status: :resting
    )

    # Message 1: User asks something
    conversation.messages.create!(
      role: 'user',
      content: 'Please run a command'
    )

    # Message 2: Assistant with tool call
    assistant_msg = conversation.messages.create!(
      role: 'assistant',
      content: ''
    )

    # Create tool use
    tool_use = assistant_msg.tool_uses.create!(
      tool_use_id: 'toolu_test456',
      name: 'bash',
      input: { command: 'ls' }
    )

    # Create tool result
    tool_use.create_tool_result!(
      message: assistant_msg,
      content: 'file1.txt\nfile2.txt',
      is_error: false
    )

    # Message 3: Assistant responds to tool result (VALID!)
    conversation.messages.create!(
      role: 'assistant',
      content: 'I found 2 files: file1.txt and file2.txt'
    )

    # Message 4: User sends another message
    conversation.messages.create!(
      role: 'user',
      content: 'Great, thanks!'
    )

    conversation
  end

  def create_conversation_with_multiple_orphan_tools
    conversation = LlmToolkit::Conversation.create!(
      conversable: @user,
      agent_type: :coder,
      status: :resting
    )

    # User message
    conversation.messages.create!(role: 'user', content: 'Do multiple things')

    # First tool call
    msg1 = conversation.messages.create!(role: 'assistant', content: '')
    tu1 = msg1.tool_uses.create!(tool_use_id: 'toolu_1', name: 'bash', input: { command: 'ls' })
    tu1.create_tool_result!(message: msg1, content: 'result1', is_error: false)

    # Error (excluded)
    conversation.messages.create!(role: 'assistant', content: 'Error 1', is_error: true)

    # Second tool call (orphan because previous error was excluded)
    msg2 = conversation.messages.create!(role: 'assistant', content: '')
    tu2 = msg2.tool_uses.create!(tool_use_id: 'toolu_2', name: 'bash', input: { command: 'pwd' })
    tu2.create_tool_result!(message: msg2, content: 'result2', is_error: false)

    # Another error (excluded)
    conversation.messages.create!(role: 'assistant', content: 'Error 2', is_error: true)

    # User message
    conversation.messages.create!(role: 'user', content: 'What happened?')

    conversation
  end
end

# Test for the image message ordering fix
# This tests that when a tool result contains an image (like screenshot),
# the user message with the image is placed AFTER all tool results,
# not between them (which breaks the API).
class ConversationImageMessageOrderingTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.find_or_create_by!(name: 'Test Tenant', subdomain: 'test-tenant-img-order')
    
    @user = User.find_by(email: 'test-img-order@example.com') || User.create!(
      email: 'test-img-order@example.com',
      password: 'password123',
      tenant: @tenant,
      role: 'user'
    )
    
    @provider = LlmToolkit::LlmProvider.find_or_create_by!(name: 'Test OpenRouter Provider') do |p|
      p.provider_type = 'openrouter'
      p.api_key = 'test_key'
    end
    
    @llm_model = LlmToolkit::LlmModel.find_or_create_by!(
      llm_provider: @provider,
      name: 'test-model'
    ) do |m|
      m.model_id = 'test/model'
    end
    
    provider = @provider
    @user.define_singleton_method(:default_llm_provider) { provider }
  end

  teardown do
    LlmToolkit::Conversation.where(conversable: @user).destroy_all
  end

  test "image messages should be placed after all tool results in the same batch" do
    conversation = create_conversation_with_screenshot_and_other_tool
    
    history = conversation.history(llm_model: @llm_model)
    
    # Find the assistant message with tool_calls
    assistant_with_tools_idx = history.find_index { |m| m[:role] == 'assistant' && m[:tool_calls].present? }
    assert assistant_with_tools_idx, "Should have an assistant message with tool_calls"
    
    assistant_msg = history[assistant_with_tools_idx]
    tool_call_ids = assistant_msg[:tool_calls].map { |tc| tc[:id] }
    
    # Verify we have 2 tool calls
    assert_equal 2, tool_call_ids.length, "Should have 2 tool calls"
    
    # Find all tool result messages
    tool_result_indices = []
    user_image_indices = []
    
    history.each_with_index do |msg, idx|
      next if idx <= assistant_with_tools_idx
      
      if msg[:role] == 'tool'
        tool_result_indices << idx
      elsif msg[:role] == 'user' && msg[:content].is_a?(Array) && msg[:content].any? { |c| c[:type] == 'image_url' }
        user_image_indices << idx
      end
    end
    
    # Verify we have both tool results
    assert_equal 2, tool_result_indices.length, "Should have 2 tool result messages"
    
    # If there are image messages, they should come AFTER all tool results
    if user_image_indices.any?
      last_tool_result_idx = tool_result_indices.max
      user_image_indices.each do |img_idx|
        assert img_idx > last_tool_result_idx, 
          "Image user message at index #{img_idx} should come after last tool result at index #{last_tool_result_idx}"
      end
    end
    
    # Verify no user messages between tool results
    (tool_result_indices.min..tool_result_indices.max).each do |idx|
      msg = history[idx]
      next if msg[:role] == 'tool'
      refute_equal 'user', msg[:role], 
        "Should not have user message at index #{idx} between tool results (#{tool_result_indices.min}..#{tool_result_indices.max})"
    end
  end

  private

  def create_conversation_with_screenshot_and_other_tool
    conversation = LlmToolkit::Conversation.create!(
      conversable: @user,
      agent_type: :coder,
      status: :resting
    )

    # User message
    conversation.messages.create!(role: 'user', content: 'Take a screenshot and check the file')

    # Assistant with TWO tool calls (screenshot + file read)
    assistant_msg = conversation.messages.create!(role: 'assistant', content: '')
    
    # Screenshot tool (will generate image)
    tu1 = assistant_msg.tool_uses.create!(
      tool_use_id: 'toolu_screenshot_123',
      name: 'lovelace_browser_screenshot',
      input: {}
    )
    # Simulated screenshot result with base64 image data
    # Must be > 100 chars to trigger image extraction (see extract_image_from_tool_result)
    fake_image_base64 = "A" * 200
    tu1.create_tool_result!(
      message: assistant_msg,
      content: "{\"result\": \"Screenshot captured\", \"data\": \"#{fake_image_base64}\"}",
      is_error: false
    )
    
    # File read tool (no image)
    tu2 = assistant_msg.tool_uses.create!(
      tool_use_id: 'toolu_fileread_456',
      name: 'str_replace_editor',
      input: { command: 'view', path: '/some/file.rb' }
    )
    tu2.create_tool_result!(
      message: assistant_msg,
      content: '{"result": "File content here..."}',
      is_error: false
    )

    conversation
  end
end
