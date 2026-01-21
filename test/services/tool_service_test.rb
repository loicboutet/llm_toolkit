require 'test_helper'

module LlmToolkit
  class ToolServiceTest < ActiveSupport::TestCase
    test "tool_definitions should return an empty array" do
      # Should always return an empty array now
      result = LlmToolkit::ToolService.tool_definitions
      
      assert_equal [], result
    end
    
    test "execute_tool should handle nil input" do
      # Mock the dependencies
      tool_use = mock('ToolUse')
      message = mock('Message')
      conversation = mock('Conversation')
      conversable = mock('Conversable')
      
      # Set up the chain of objects
      tool_use.stubs(:message).returns(message)
      tool_use.stubs(:name).returns('test_tool')
      tool_use.stubs(:input).returns(nil)
      tool_use.stubs(:create_tool_result!).returns(true)
      message.stubs(:conversation).returns(conversation)
      conversation.stubs(:conversable).returns(conversable)
      
      # Mock the tool class - now accepts tool_use parameter too
      test_tool = mock('TestTool')
      test_tool.stubs(:execute).with(conversable: conversable, args: {}, tool_use: tool_use).returns({ result: "test result" })
      
      # Mock finding the tool
      LlmToolkit::Tools::AbstractTool.stubs(:find_tool).with('test_tool').returns(test_tool)
      
      # Execute the method - should not raise an error
      LlmToolkit::ToolService.execute_tool(tool_use)
    end
    
    test "execute_tool should handle empty string input" do
      # Mock the dependencies
      tool_use = mock('ToolUse')
      message = mock('Message')
      conversation = mock('Conversation')
      conversable = mock('Conversable')
      
      # Set up the chain of objects
      tool_use.stubs(:message).returns(message)
      tool_use.stubs(:name).returns('test_tool')
      tool_use.stubs(:input).returns("")
      tool_use.stubs(:create_tool_result!).returns(true)
      message.stubs(:conversation).returns(conversation)
      conversation.stubs(:conversable).returns(conversable)
      
      # Mock the tool class - now accepts tool_use parameter too
      test_tool = mock('TestTool')
      test_tool.stubs(:execute).with(conversable: conversable, args: {}, tool_use: tool_use).returns({ result: "test result" })
      
      # Mock finding the tool
      LlmToolkit::Tools::AbstractTool.stubs(:find_tool).with('test_tool').returns(test_tool)
      
      # Execute the method - should not raise an error
      LlmToolkit::ToolService.execute_tool(tool_use)
    end
  end
end