# Error Message Handling for OpenRouter API

This document describes the error handling implementation for OpenRouter API failures in the LLM Toolkit.

## Overview

When OpenRouter returns API errors (like "No endpoints found that support tool use" or "insufficient credits"), the system now creates user-friendly error messages instead of crashing or showing technical error details to users.

## Key Features

1. **User-friendly French error messages** - All API errors are translated to clear, actionable messages in French
2. **Proper error display** - Error messages are displayed with distinct styling in the UI
3. **No duplicate error handling** - Errors handled during streaming are not re-raised after
4. **Conversation history filtering** - Error messages are excluded from future LLM context

## Supported Error Types

### 1. Payment/Credits Errors (HTTP 402)
- Pattern: `requires more credits`, `can only afford`, `add more credits`, `insufficient.*credits`
- Message: "Crédits insuffisants pour cette requête. Veuillez recharger votre compte OpenRouter pour continuer."

### 2. Tool Support Errors
- Pattern: `no endpoints found that support tool use`
- Message: "Le modèle sélectionné ne prend pas en charge les outils avancés."

### 3. Rate Limiting (HTTP 429)
- Pattern: `rate limit`, `too many requests`
- Message: "Le service est temporairement surchargé. Veuillez réessayer dans quelques instants."

### 4. Model Availability
- Pattern: `model .* not found`, `model.*does not exist`
- Message: "Le modèle demandé n'est pas disponible. Essayez de sélectionner un autre modèle."

### 5. Context Length Errors (HTTP 413)
- Pattern: `context.*too long`, `maximum context length`, `max.*tokens.*exceeded`
- Message: "La conversation est devenue trop longue. Veuillez démarrer une nouvelle conversation."

### 6. Content Filtering
- Pattern: `content.*filter`, `safety`, `blocked`
- Message: "Le contenu a été filtré pour des raisons de sécurité."

### 7. Authentication Errors (HTTP 401, 403)
- Pattern: `authentication`, `unauthorized`, `api.?key`, `invalid.*key`
- Message: "Erreur d'authentification avec le service. Veuillez contacter l'administrateur."

### 8. Tool Synchronization Errors
- Pattern: `tool_use.*without.*tool_result`, `tool_result.*tool_use_id`
- Message: "Erreur de synchronisation des outils. Veuillez réessayer ou démarrer une nouvelle conversation."

### 9. Server Errors (HTTP 502, 503, 504)
- Pattern: `server.*error`, `internal.*error`, `overloaded`, `capacity`
- Message: "Le service est temporairement indisponible. Veuillez réessayer dans quelques instants."

### 10. Timeout Errors
- Pattern: `timeout`
- Message: "La requête a pris trop de temps. Veuillez réessayer."

### 11. Quota Errors
- Pattern: `quota`, `limit.*exceeded`
- Message: "Quota dépassé. Veuillez contacter l'administrateur ou réessayer plus tard."

### 12. Invalid Request Errors
- Pattern: `invalid_request_error` with message content patterns
- Message: Context-specific invalid request message

## Architecture

### Error Flow

```
OpenRouter API Error (during streaming)
        ↓
Error detected in SSE line parsing
        ↓
translate_api_error_to_friendly_message(error_message, error_code)
        ↓
Mark error_handled_via_stream = true
        ↓
Yield 'error' chunk with friendly message
        ↓
CallStreamingLlmWithToolService.process_chunk handles 'error' chunk
        ↓
Message updated with:
  - content: friendly_message
  - is_error: true  
  - finish_reason: 'error'
        ↓
After streaming, API status is checked
        ↓
If error_handled_via_stream, don't re-raise (return gracefully)
        ↓
UI displays error with special red styling
        ↓
Error message excluded from future conversation history
```

### Key Files

1. **`llm_toolkit/app/models/llm_toolkit/llm_provider/openrouter_handler.rb`**
   - `translate_api_error_to_friendly_message` - Converts API errors to French user messages
   - `process_sse_line` - Detects errors in streaming and sets `error_handled_via_stream`
   - `stream_openrouter` - Checks flag to avoid re-raising handled errors

2. **`llm_toolkit/app/services/llm_toolkit/call_streaming_llm_with_tool_service.rb`**
   - `process_chunk` - Handles 'error' chunk type and updates message

3. **`app/views/messages/_message.html.erb`**
   - Error message rendering with distinct styling

4. **`app/views/messages/_message_nexrai.html.erb`**
   - Error message rendering for nexrai theme with red warning styling

## UI Display

Error messages are displayed with:
- **Red warning icon** instead of lightning bolt
- **Red-tinted background** (rgba(127, 29, 29, 0.3))
- **Red text color** (#fca5a5 for content, #f87171 for header)
- **Red border** (rgba(127, 29, 29, 0.5))
- **"Erreur" header** with exclamation icon
- **Retry suggestion** at the bottom

### Example Error Display

```
┌─────────────────────────────────────────────┐
│ ⚠ Erreur                                     │
├─────────────────────────────────────────────┤
│ Crédits insuffisants pour cette requête.    │
│ Veuillez recharger votre compte OpenRouter  │
│ pour continuer.                             │
├─────────────────────────────────────────────┤
│ ↻ Essayez d'envoyer votre message à         │
│   nouveau ou démarrez une nouvelle          │
│   conversation.                             │
└─────────────────────────────────────────────┘
```

## Error Message Properties

Error messages have these characteristics:
- `is_error: true` - Boolean flag marking them as errors
- `role: 'assistant'` - Appears as assistant messages
- `finish_reason: 'error'` - Special finish reason
- Excluded from conversation history for future LLM calls
- Special CSS styling in the UI

## Testing

To test error handling:

1. **Credits error**: Use an OpenRouter account with insufficient credits
2. **Tool support error**: Select a model that doesn't support tools and send a message
3. **Rate limit**: Send many requests in quick succession
4. **Context length**: Create a very long conversation

In all cases, you should see a user-friendly French error message with red styling.

## Adding New Error Types

To add a new error pattern:

1. Edit `translate_api_error_to_friendly_message` in `openrouter_handler.rb`
2. Add a new `when` clause with regex pattern
3. Return a user-friendly French message
4. The error will automatically be handled by the existing infrastructure

Example:
```ruby
when /new_error_pattern/i
  "Nouveau message d'erreur en français pour l'utilisateur."
```

## Configuration

The error handler uses French messages by default. To customize:

1. Modify `translate_api_error_to_friendly_message` for different languages
2. Adjust view partials for different error styling
3. Modify CSS in `error_messages.css` for styling changes

## Migration Instructions

1. Run the migration: `rails db:migrate`
2. Restart the Rails application
3. Error handling is automatic for all streaming calls
