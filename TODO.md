# DuckDB Crawler - TODO

## Current Capabilities

┌────────────────────┬─────────┬──────────────────────────────────────────────────────┐
│      Feature       │ Support │                        Notes                         │
├────────────────────┼─────────┼──────────────────────────────────────────────────────┤
│ HTTP/1.1           │ ✅      │ Full support via libcurl                             │
├────────────────────┼─────────┼──────────────────────────────────────────────────────┤
│ HTTP/2             │ ✅      │ Via libcurl + nghttp2                                │
├────────────────────┼─────────┼──────────────────────────────────────────────────────┤
│ HTTP/3             │ ❌      │ Blocked by vcpkg OpenSSL QUIC issue (see below)      │
├────────────────────┼─────────┼──────────────────────────────────────────────────────┤
│ Keep-alive         │ ✅      │ Via libcurl                                          │
├────────────────────┼─────────┼──────────────────────────────────────────────────────┤
│ Connection pooling │ ✅      │ Thread-safe curl handle pool (max 100 handles)       │
└────────────────────┴─────────┴──────────────────────────────────────────────────────┘

## HTTP/3 Options

ngtcp2 fails to build because vcpkg's OpenSSL 3.6.0 doesn't expose QUIC APIs.
Compile-time macros `CRAWLER_HTTP3_SUPPORT` are ready - just need working deps.

### Option 1: Use wolfSSL (Recommended)

vcpkg's wolfssl has `quic` feature. Update `vcpkg.json`:
```json
{
    "dependencies": [
        "zlib",
        {"name": "wolfssl", "features": ["quic"]},
        {"name": "ngtcp2", "features": ["wolfssl"]},
        {"name": "nghttp3"},
        {"name": "curl", "default-features": false, "features": ["ssl", "wolfssl", "http2", "http3"]}
    ]
}
```

### Option 2: Wait for vcpkg OpenSSL QUIC fix

OpenSSL 3.5+ has QUIC APIs but vcpkg's port doesn't enable them.
- Discussion: https://github.com/microsoft/vcpkg/discussions/27400
- Could file issue requesting `openssl` port add `quic` feature

### Option 3: Use system OpenSSL

macOS Homebrew or system OpenSSL might have QUIC enabled.
Would need to bypass vcpkg for TLS libs.

## Current Issues

### 1. True multi-threading not implemented (F1)
**Status**: Backlog

- Single-threaded crawl processing
- Would provide 10-50x throughput for multi-domain crawls
- Requires per-domain locks, thread pool

## Implemented Features

- [x] F2: Connection pooling (libcurl handle pool)
- [x] F3: Batch inserts
- [x] F5: Parallel sitemap discovery
- [x] G6: Progress reporting
- [x] G7: Error classification
- [x] C1: Compression (Accept-Encoding)
- [x] C2: Response size limits
- [x] C3: Content-Type filtering
- [x] N3: Request-rate support
- [x] N8: Global connection limit
- [x] ETag/Last-Modified headers
- [x] Content hash deduplication
- [x] SURT keys for URL normalization
- [x] Adaptive rate limiting
- [x] Priority queue scheduling
- [x] Gzip sitemap decompression
- [x] HTTP/2 support (libcurl + nghttp2)
- [x] G5: Redirect tracking (final_url, redirect_count columns)
- [x] N5: Meta robots tag support (noindex clears body, nofollow skips link extraction)
- [x] Large HTTP headers support (libcurl has no header size limit)
