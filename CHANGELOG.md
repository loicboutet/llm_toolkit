# Changelog

All notable changes to LlmToolkit will be documented in this file.

## [Unreleased]

### Added
- **Anthropic Streaming Support**: Added native streaming support for Anthropic API via `stream_anthropic` method
  - Full SSE (Server-Sent Events) parsing for real-time token streaming
  - Tool use support during streaming
  - Cache token tracking (cache_creation_input_tokens, cache_read_input_tokens)
  - Proper error handling with French-localized error messages

- **Centralized Configuration**: Added new configuration options to `LlmToolkit.configure`:
  - `streaming_throttle_ms` (default: 50) - Throttle interval for broadcast updates
  - `max_tool_followups` (default: 100) - Safety limit for tool followup loops
  - `max_tool_result_size` (default: 50,000) - Maximum characters for tool results
  - `placeholder_markers` - Customizable placeholder messages for streaming UI

- **User ID Propagation**: Improved `user_id` handling in conversation methods
  - Added explicit `user_id:` parameter to `chat`, `stream_chat`, and async variants
  - Cleaner fallback to `Thread.current[:current_user_id]` when not provided

### Changed
- **LlmProvider#stream_chat**: Now supports both `anthropic` and `openrouter` provider types
- **LlmProvider#supports_streaming?**: New method to check if provider supports streaming
- **Conversation#stream_chat**: Updated to use `supports_streaming?` instead of hardcoded provider check
- **Message model**: Now uses `LlmToolkit.config.streaming_throttle_ms` instead of hardcoded constant
- **Message#placeholder_content?**: Now delegates to `LlmToolkit.config.placeholder_content?`
- **Conversation model**: Now uses `LlmToolkit.config.max_tool_result_size` for truncation threshold

### Removed
- Hardcoded `STREAMING_THROTTLE_MS` constant from Message model
- Hardcoded `MAX_TOOL_RESULT_SIZE` constant from Conversation model
- Hardcoded `PLACEHOLDER_MARKERS` constant from Message model
- Hardcoded `@max_followups` from CallStreamingLlmWithToolService

### Fixed
- `placeholder_content?` helper now uses pure Ruby methods for better compatibility

## [Previous Versions]

See git history for previous changes.
