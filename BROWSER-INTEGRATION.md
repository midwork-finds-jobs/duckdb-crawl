# Browser Integration: Lightpanda for JavaScript Rendering

This document proposes integrating [Lightpanda](https://github.com/lightpanda-io/browser) into duckdb-crawler for cases where bare HTTP requests are insufficient.

## Problem Statement

The current crawler explicitly does **not** support JavaScript rendering (see `specification.md` Non-Goals). This means:

- **SPAs fail**: React, Vue, Angular apps return empty shells
- **Anti-bot protection**: Cloudflare, Akamai challenges require JS execution
- **Dynamic content**: Infinite scroll, lazy loading, AJAX-populated content invisible
- **Modern web reality**: Significant portion of sites now require JS to render meaningful content

The `audit.md` identifies this as a critical gap: *"completely lacks the ability to execute client-side JavaScript, rendering it useless for a significant portion of the modern web."*

## Why Lightpanda

| Feature | Lightpanda | Chrome/Puppeteer |
|---------|------------|------------------|
| **Speed** | 11x faster | Baseline |
| **Memory** | 9x lower | ~500MB+ per instance |
| **Language** | Zig (C ABI compatible) | C++ |
| **Protocol** | CDP (Playwright/Puppeteer compatible) | CDP |
| **Design** | Headless-first, no GUI | Full browser with headless mode |
| **Footprint** | Lightweight, embeddable | Heavy, separate process |

Lightpanda is purpose-built for automation - fast enough to be practical for crawling, light enough to potentially embed.

## Architecture Options

### Option A: CDP Sidecar (Recommended)

Run Lightpanda as a separate process, communicate via Chrome DevTools Protocol over WebSocket.

```
┌─────────────────────────────────────────────────────────────────┐
│                        DuckDB Engine                            │
├─────────────────────────────────────────────────────────────────┤
│                   Crawler Extension                             │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ HTTP Client  │    │ CDP Client   │    │ Render Strategy  │  │
│  │ (existing)   │    │ (new)        │    │ Selector         │  │
│  └──────┬───────┘    └──────┬───────┘    └────────┬─────────┘  │
│         │                   │                     │             │
└─────────┼───────────────────┼─────────────────────┼─────────────┘
          │                   │                     │
          │                   │ WebSocket           │
          │                   │ CDP Protocol        │
          │                   ▼                     │
          │            ┌──────────────┐             │
          │            │  Lightpanda  │             │
          │            │  (sidecar)   │             │
          │            └──────────────┘             │
          │                   │                     │
          ▼                   ▼                     │
     ┌─────────────────────────────┐               │
     │         Internet            │◄──────────────┘
     └─────────────────────────────┘
```

**Pros:**
- Clean separation of concerns
- No build complexity (binary download)
- Independent version upgrades
- Crash isolation (browser crash doesn't kill DuckDB)
- Works with Docker deployment

**Cons:**
- Process lifecycle management needed
- WebSocket latency overhead (~1-5ms per message)
- External dependency at runtime

**Implementation sketch:**

```cpp
// New file: src/browser_client.cpp

class BrowserClient {
public:
    BrowserClient(const string& ws_endpoint);

    // Navigate and wait for content
    HttpResponse Fetch(const string& url, const BrowserOptions& opts);

private:
    WebSocketConnection ws_conn;
    int next_message_id = 1;

    json SendCommand(const string& method, const json& params);
    string WaitForPageLoad(const string& wait_until);
};

struct BrowserOptions {
    string wait_until = "networkidle";  // or "domcontentloaded", "load"
    int timeout_ms = 30000;
    bool block_images = false;
    bool block_fonts = false;
    vector<string> block_patterns;      // e.g., "*.analytics.com/*"
};
```

### Option B: Library Linking

Build Lightpanda as a static library and link via C ABI.

```
┌─────────────────────────────────────────────────────────────────┐
│                        DuckDB Engine                            │
├─────────────────────────────────────────────────────────────────┤
│                   Crawler Extension                             │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────────────────────────┐  │
│  │ HTTP Client  │    │ Lightpanda (statically linked)       │  │
│  │ (existing)   │    │ - V8 JavaScript Engine               │  │
│  │              │    │ - HTML5 Parser (html5ever)           │  │
│  │              │    │ - HTTP Client (libcurl)              │  │
│  └──────────────┘    └──────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Pros:**
- No IPC overhead
- Single binary distribution
- No runtime dependencies
- Simpler deployment

**Cons:**
- Complex build system (Zig toolchain + C++ + DuckDB)
- Version coupling (must rebuild to upgrade Lightpanda)
- Larger binary size (~100MB+ with V8)
- Memory shared with DuckDB process (crashes affect DB)
- V8 initialization overhead per extension load

**Implementation sketch:**

```cpp
// Would require C bindings from Lightpanda
// Currently not officially supported - would need upstream contribution

extern "C" {
    void* lightpanda_browser_new();
    void lightpanda_browser_free(void* browser);
    char* lightpanda_fetch(void* browser, const char* url, int timeout_ms);
    void lightpanda_free_string(char* str);
}
```

## Trigger Modes

### Mode 1: Manual Trigger

User explicitly requests browser rendering:

```sql
-- Explicit render_js option
CRAWL 'https://spa.example.com'
INTO results
WITH (render_js true);

-- Or with additional browser options
CRAWL 'https://spa.example.com'
INTO results
WITH (
    render_js true,
    render_wait 'networkidle',    -- 'load', 'domcontentloaded', 'networkidle'
    render_timeout 30000,         -- ms
    render_block_images true      -- reduce bandwidth
);
```

**Pros:**
- Predictable behavior
- No false positives
- User controls resource usage

**Cons:**
- User must know which sites need JS
- Manual per-URL or per-domain configuration

### Mode 2: Auto-Fallback

Try HTTP first, automatically fallback to browser on detection heuristics:

```sql
-- Enable auto-fallback globally
SET crawler_render_auto = true;

-- Or per-crawl
CRAWL 'https://example.com'
INTO results
WITH (render_auto true);
```

**Detection heuristics:**

1. **Empty body**: `<body>` contains only `<script>` tags or minimal content
2. **SPA frameworks**: Detect React root `<div id="root">`, Vue `<div id="app">`, etc.
3. **Loader indicators**: "Loading...", spinner CSS classes
4. **Meta tags**: `<meta name="fragment" content="!">` (AJAX crawling scheme)
5. **Anti-bot responses**: Cloudflare challenge page signatures, CAPTCHA indicators
6. **HTTP 403/503 with challenge**: Challenge-response pages

**Pros:**
- Works automatically for mixed sites
- Efficient for static content (HTTP only)
- Graceful degradation

**Cons:**
- Heuristics can have false positives/negatives
- Double request overhead on fallback
- More complex implementation

**Implementation sketch:**

```cpp
bool NeedsBrowserRendering(const HttpResponse& resp) {
    if (resp.status == 403 || resp.status == 503) {
        if (DetectCloudflareChallenge(resp.body)) return true;
    }

    if (DetectEmptySPAShell(resp.body)) return true;
    if (DetectJSFrameworkRoot(resp.body)) return true;

    return false;
}

HttpResponse FetchWithAutoFallback(const string& url, const CrawlOptions& opts) {
    // Try HTTP first
    auto resp = http_client.Fetch(url);

    if (opts.render_auto && NeedsBrowserRendering(resp)) {
        // Fallback to browser
        resp = browser_client.Fetch(url, opts.browser_opts);
        resp.rendered_with_browser = true;
    }

    return resp;
}
```

## Implementation Considerations

### Process Lifecycle (CDP Sidecar)

```cpp
class LightpandaManager {
public:
    // Start on first use, lazy initialization
    void EnsureRunning();

    // Graceful shutdown on extension unload
    void Shutdown();

    // Health check and restart if crashed
    bool IsHealthy();
    void Restart();

private:
    pid_t browser_pid = -1;
    string ws_endpoint;
    int port = 9222;  // Default CDP port
};
```

**Startup command:**
```bash
lightpanda --headless --remote-debugging-port=9222
```

### Resource Management

```cpp
struct BrowserLimits {
    int max_concurrent_pages = 4;       // Limit memory usage
    int page_timeout_ms = 30000;        // Kill stuck pages
    size_t max_response_size = 10 * 1024 * 1024;  // 10MB limit
    int max_redirects = 10;
};
```

### Wait Strategies

| Strategy | Description | Use Case |
|----------|-------------|----------|
| `load` | Wait for `load` event | Simple pages |
| `domcontentloaded` | Wait for DOM ready | Faster, may miss async |
| `networkidle` | Wait for network quiet (0 requests for 500ms) | SPAs, AJAX content |
| `selector` | Wait for specific CSS selector | Known element needed |

```sql
-- Wait for specific element
CRAWL 'https://spa.example.com'
INTO results
WITH (
    render_js true,
    render_wait_selector '.product-list'
);
```

### Resource Blocking

Reduce bandwidth and speed up rendering:

```cpp
struct ResourceBlockingConfig {
    bool block_images = false;
    bool block_fonts = false;
    bool block_stylesheets = false;  // Careful: may break layout detection
    vector<string> block_patterns;   // URL patterns to block
};
```

### Cookie/Session Persistence

```sql
-- Persist cookies across requests (for login sessions)
CRAWL 'https://example.com/dashboard'
INTO results
WITH (
    render_js true,
    render_cookie_jar '/path/to/cookies.json'
);
```

### Output Schema Extension

Add browser-specific columns:

```sql
CREATE TABLE crawl_results (
    url VARCHAR,
    status INTEGER,
    body VARCHAR,
    content_type VARCHAR,

    -- New columns for browser rendering
    rendered_with_browser BOOLEAN DEFAULT false,
    render_time_ms INTEGER,           -- Time spent in browser
    js_errors VARCHAR[],              -- Console errors captured
    final_url VARCHAR,                -- After JS redirects
    screenshot BLOB                   -- Optional: screenshot for debugging
);
```

## Configuration Options

```sql
-- Global settings
SET crawler_browser_endpoint = 'ws://localhost:9222';  -- CDP endpoint
SET crawler_browser_auto_start = true;                  -- Auto-start sidecar
SET crawler_browser_path = '/usr/local/bin/lightpanda'; -- Binary path

-- Per-crawl options (WITH clause)
render_js              BOOLEAN   -- Enable browser rendering
render_auto            BOOLEAN   -- Auto-detect and fallback
render_wait            VARCHAR   -- 'load', 'domcontentloaded', 'networkidle'
render_wait_selector   VARCHAR   -- CSS selector to wait for
render_timeout         INTEGER   -- Page timeout in ms
render_block_images    BOOLEAN   -- Block image loading
render_block_fonts     BOOLEAN   -- Block font loading
render_cookie_jar      VARCHAR   -- Path to cookie persistence file
```

## Migration Path

### Phase 1: CDP Sidecar (MVP)
1. Add `BrowserClient` class with CDP WebSocket implementation
2. Add `render_js` option to CRAWL syntax
3. Manual Lightpanda process management (user starts it)
4. Basic wait strategies: `load`, `networkidle`

### Phase 2: Auto-Management
1. Add `LightpandaManager` for automatic process lifecycle
2. Docker support with Lightpanda container
3. Health monitoring and auto-restart

### Phase 3: Auto-Fallback
1. Implement detection heuristics
2. Add `render_auto` option
3. Heuristic tuning based on real-world testing

### Phase 4: Advanced Features
1. Cookie/session persistence
2. Resource blocking configuration
3. Screenshot capture for debugging
4. Custom JavaScript injection

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Playwright/Puppeteer** | Mature, well-documented | Node.js dependency, heavy |
| **Chrome Headless** | Full compatibility | 500MB+ memory, slow startup |
| **Splash (Lua)** | Docker-ready | Python dependency, less maintained |
| **Crawlee** | Full-featured crawler | Requires Node.js runtime |
| **Lightpanda** | Fast, lightweight, C-compatible | Newer, less mature |

Lightpanda chosen for:
- Performance characteristics suitable for crawling workloads
- C ABI compatibility for potential future embedding
- CDP support for immediate sidecar integration
- Active development and open-source

## References

- [Lightpanda GitHub](https://github.com/lightpanda-io/browser)
- [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
- [Puppeteer CDP Implementation](https://pptr.dev/)
- [DuckDB Extension Development](https://duckdb.org/docs/extensions/overview)
