#
# AI provider abstraction
#
# Supported providers:
#   claude-code  — uses local Claude Code CLI (zero config, best quality)
#   anthropic    — Anthropic API (requires API key)
#   gemini       — Google Gemini API (requires API key)
#   openai       — OpenAI-compatible (Ollama, Groq, etc.)
#
# Both helpme.zsh and suggest.zsh call _sage_api_call() which routes
# to the correct provider based on ZSH_SAGE_AI_PROVIDER.
#

# ── Dispatcher ───────────────────────────────────────────────────

# Call the configured AI provider with a prompt, return the response text.
# Args: prompt [max_tokens]
# Returns: suggestion text on stdout, error messages on stderr
# Exit code: 0 on success, 1 on failure
_sage_api_call() {
    local prompt="$1"
    local max_tokens="${2:-200}"

    local json_prompt
    json_prompt=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    local response=""
    local curl_exit=0

    # Claude Code provider — direct CLI call, no curl/parse needed
    if [[ "$ZSH_SAGE_AI_PROVIDER" == "claude-code" ]]; then
        local suggestion
        suggestion=$(claude -p "$prompt" --max-turns 1 2>/dev/null)
        if [[ $? -ne 0 || -z "$suggestion" ]]; then
            echo "  Claude Code failed. Is 'claude' installed and working?" >&2
            echo "  Try: claude --version" >&2
            return 1
        fi
        suggestion=$(_sage_api_strip_formatting "$suggestion")
        printf '%s' "$suggestion"
        return 0
    fi

    case "$ZSH_SAGE_AI_PROVIDER" in
        anthropic)
            response=$(_sage_api_curl_anthropic "$json_prompt" "$max_tokens")
            curl_exit=$?
            ;;
        gemini)
            response=$(_sage_api_curl_gemini "$json_prompt" "$max_tokens")
            curl_exit=$?
            ;;
        openai)
            response=$(_sage_api_curl_openai "$json_prompt" "$max_tokens")
            curl_exit=$?
            ;;
        *)
            echo "  Unknown provider: $ZSH_SAGE_AI_PROVIDER" >&2
            echo "  Valid options: claude-code, gemini, anthropic, openai" >&2
            return 1
            ;;
    esac

    # Check for connection failures
    if (( curl_exit == 28 )); then
        echo "  Request timed out — the API took too long to respond." >&2
        return 1
    elif (( curl_exit != 0 )); then
        echo "  Could not connect to the API. Check your network." >&2
        return 1
    fi

    # Parse response per provider
    local suggestion=""
    case "$ZSH_SAGE_AI_PROVIDER" in
        anthropic) suggestion=$(_sage_api_parse_anthropic "$response") ;;
        gemini)    suggestion=$(_sage_api_parse_gemini "$response") ;;
        openai)    suggestion=$(_sage_api_parse_openai "$response") ;;
    esac

    # Check if parsing returned an error (starts with "ERR:")
    if [[ "$suggestion" == ERR:* ]]; then
        echo "  ${suggestion#ERR:}" >&2
        return 1
    fi

    # Strip markdown/backtick wrapping that models sometimes add
    suggestion=$(_sage_api_strip_formatting "$suggestion")

    printf '%s' "$suggestion"
}

# ── Anthropic ────────────────────────────────────────────────────

_sage_api_curl_anthropic() {
    local json_prompt="$1"
    local max_tokens="$2"

    curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${ZSH_SAGE_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -d "{
            \"model\": \"${ZSH_SAGE_AI_MODEL}\",
            \"max_tokens\": ${max_tokens},
            \"messages\": [{
                \"role\": \"user\",
                \"content\": ${json_prompt}
            }]
        }" \
        "${ZSH_SAGE_API_BASE}/v1/messages" 2>/dev/null
}

_sage_api_parse_anthropic() {
    printf '%s' "$1" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'error' in data:
        t = data['error'].get('type', '')
        m = data['error'].get('message', '')
        if t == 'authentication_error':
            print('ERR:Invalid API key. Check your ZSH_SAGE_API_KEY.')
        elif t == 'rate_limit_error':
            print('ERR:Rate limited — try again in a moment.')
        elif t == 'overloaded_error':
            print('ERR:API is overloaded. Try again in a few seconds.')
        else:
            print('ERR:API error: ' + m)
    else:
        print(data['content'][0]['text'].strip())
except Exception as e:
    print('ERR:Failed to parse API response.')
" 2>/dev/null
}

# ── Gemini ───────────────────────────────────────────────────────

_sage_api_curl_gemini() {
    local json_prompt="$1"
    local max_tokens="$2"

    curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -d "{
            \"contents\": [{
                \"parts\": [{
                    \"text\": ${json_prompt}
                }]
            }],
            \"generationConfig\": {
                \"maxOutputTokens\": ${max_tokens}
            }
        }" \
        "${ZSH_SAGE_API_BASE}/v1beta/models/${ZSH_SAGE_AI_MODEL}:generateContent?key=${ZSH_SAGE_API_KEY}" 2>/dev/null
}

_sage_api_parse_gemini() {
    printf '%s' "$1" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'error' in data:
        code = data['error'].get('code', 0)
        msg = data['error'].get('message', '')
        if code == 400:
            print('ERR:Invalid request. Check your API key and model.')
        elif code == 403:
            print('ERR:API key not authorized. Check your Gemini API key.')
        elif code == 429:
            print('ERR:Rate limited — try again in a moment.')
        else:
            print('ERR:API error: ' + msg)
    else:
        print(data['candidates'][0]['content']['parts'][0]['text'].strip())
except Exception as e:
    print('ERR:Failed to parse API response.')
" 2>/dev/null
}

# ── OpenAI-compatible (also works with Ollama) ───────────────────

_sage_api_curl_openai() {
    local json_prompt="$1"
    local max_tokens="$2"

    local -a auth_header=()
    if [[ -n "$ZSH_SAGE_API_KEY" ]]; then
        auth_header=(-H "Authorization: Bearer ${ZSH_SAGE_API_KEY}")
    fi

    # Longer timeout for local models (Ollama first inference loads the model)
    local timeout=10
    [[ "$ZSH_SAGE_API_BASE" == *"localhost"* ]] && timeout=30

    curl -s --max-time "$timeout" \
        -H "Content-Type: application/json" \
        "${auth_header[@]}" \
        -d "{
            \"model\": \"${ZSH_SAGE_AI_MODEL}\",
            \"max_tokens\": ${max_tokens},
            \"messages\": [{
                \"role\": \"user\",
                \"content\": ${json_prompt}
            }]
        }" \
        "${ZSH_SAGE_API_BASE}/v1/chat/completions" 2>/dev/null
}

_sage_api_parse_openai() {
    printf '%s' "$1" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'error' in data:
        msg = data['error'].get('message', '') if isinstance(data['error'], dict) else str(data['error'])
        if 'auth' in msg.lower() or 'api key' in msg.lower():
            print('ERR:Invalid API key. Check your ZSH_SAGE_API_KEY.')
        elif 'rate' in msg.lower():
            print('ERR:Rate limited — try again in a moment.')
        else:
            print('ERR:API error: ' + msg)
    else:
        print(data['choices'][0]['message']['content'].strip())
except Exception as e:
    print('ERR:Failed to parse API response.')
" 2>/dev/null
}

# ── Shared: strip markdown formatting ────────────────────────────

_sage_api_strip_formatting() {
    local text="$1"

    # Use python for reliable stripping
    printf '%s' "$text" | python3 -c "
import sys
text = sys.stdin.read().strip()
# Strip triple backticks
if text.startswith('\`\`\`') and text.endswith('\`\`\`'):
    text = text[3:-3].strip()
    if '\n' in text:
        first_line = text.split('\n')[0]
        if first_line in ('bash', 'sh', 'zsh', 'shell', 'fish'):
            text = '\n'.join(text.split('\n')[1:]).strip()
# Strip single backticks
if text.startswith('\`') and text.endswith('\`') and text.count('\`') == 2:
    text = text[1:-1]
# Strip surrounding quotes
if (text.startswith('\"') and text.endswith('\"')) or (text.startswith(\"'\") and text.endswith(\"'\")):
    text = text[1:-1]
print(text)
" 2>/dev/null
}
