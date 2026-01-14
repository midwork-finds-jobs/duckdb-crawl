# DuckDB Crawler Extension

A DuckDB extension for web crawling with automatic rate limiting, robots.txt compliance, and sitemap discovery.

## Features

- **CRAWL SQL syntax** - Native SQL command for crawling
- **Two modes**: Direct URL crawling or sitemap-based site discovery
- **robots.txt compliance** - Crawl-delay, Request-rate, Disallow/Allow rules
- **Adaptive rate limiting** - Adjusts delay based on server response times
- **Parallel sitemap discovery** - Fast site enumeration
- **Conditional requests** - ETag/Last-Modified support for efficient re-crawling
- **Content deduplication** - SHA-256 content hash
- **SURT key normalization** - Common Crawl compatible URL keys
- **Crash recovery** - Persistent queue survives interruptions
- **Progress tracking** - Monitor crawl status via `_crawl_progress_{table}`
- **Graceful shutdown** - Ctrl+C stops cleanly, double Ctrl+C force exits

## Installation

```sql
INSTALL crawler FROM community;
LOAD crawler;
```

## Usage

### CRAWL - Direct URL Crawling

```sql
-- Create target table (auto-created if doesn't exist)
CRAWL (SELECT 'https://example.com/page1' AS url)
INTO crawl_results
WITH (user_agent 'MyBot/1.0 (+https://example.com/bot)');

-- Crawl URLs from a table
CRAWL (SELECT url FROM urls_to_crawl)
INTO crawl_results
WITH (user_agent 'MyBot/1.0');
```

### CRAWL SITES - Sitemap Discovery Mode

```sql
-- Discover all URLs from sitemap and crawl them
CRAWL SITES (SELECT 'example.com')
INTO crawl_results
WITH (user_agent 'MyBot/1.0');

-- Filter discovered URLs with LIKE pattern
CRAWL SITES (SELECT hostname FROM sites)
INTO products
WHERE url LIKE '%/product/%'
WITH (
    user_agent 'ProductBot/1.0',
    sitemap_cache_hours 48
);
```

### Full Example with Options

```sql
CRAWL SITES (SELECT 'shop.example.com')
INTO product_pages
WHERE url LIKE '%/products/%'
WITH (
    user_agent 'ShopCrawler/1.0 (+https://mysite.com/bot)',
    default_crawl_delay 0.5,
    max_crawl_delay 10.0,
    timeout_seconds 30,
    max_parallel_per_domain 4,
    accept_content_types 'text/html',
    compress true
);
```

## Output Schema

The target table is created automatically with this schema:

| Column | Type | Description |
|--------|------|-------------|
| url | VARCHAR | Crawled URL |
| surt_key | VARCHAR | SURT-normalized URL key (Common Crawl format) |
| domain | VARCHAR | Domain extracted from URL |
| http_status | INTEGER | HTTP status code (200, 404, etc.) or -1 for disallowed |
| body | VARCHAR | Response body |
| content_type | VARCHAR | Content-Type header |
| elapsed_ms | BIGINT | Request time in milliseconds |
| crawled_at | TIMESTAMP | When the URL was crawled |
| error | VARCHAR | Error message if failed |
| error_type | VARCHAR | Classified error (network_timeout, http_rate_limited, etc.) |
| etag | VARCHAR | ETag header for conditional requests |
| last_modified | VARCHAR | Last-Modified header |
| content_hash | VARCHAR | SHA-256 hash of response body |

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| user_agent | VARCHAR | **required** | User-Agent header (used for robots.txt matching) |
| default_crawl_delay | DOUBLE | 1.0 | Default delay between requests (seconds) |
| min_crawl_delay | DOUBLE | 0.0 | Minimum delay floor |
| max_crawl_delay | DOUBLE | 60.0 | Maximum delay cap |
| timeout_seconds | INTEGER | 30 | HTTP request timeout |
| respect_robots_txt | BOOLEAN | true | Parse and respect robots.txt |
| log_skipped | BOOLEAN | true | Include skipped URLs in output |
| sitemap_cache_hours | DOUBLE | 24.0 | Hours to cache sitemap discovery |
| update_stale | BOOLEAN | false | Re-crawl URLs with newer lastmod in sitemap |
| max_retry_backoff_seconds | INTEGER | 600 | Max Fibonacci backoff for 429/5XX (10 min) |
| max_parallel_per_domain | INTEGER | 8 | Max concurrent requests per domain |
| max_total_connections | INTEGER | 32 | Global max concurrent connections |
| max_response_bytes | BIGINT | 10485760 | Max response size (10MB) |
| compress | BOOLEAN | true | Request gzip/deflate compression |
| accept_content_types | VARCHAR | '' | Only accept these types (comma-separated, e.g., 'text/html,text/*') |
| reject_content_types | VARCHAR | '' | Reject these types |

## Auxiliary Tables

The extension creates helper tables automatically:

- `_crawl_queue_{table}` - Persistent queue for crash recovery
- `_crawl_progress_{table}` - Crawl progress and statistics
- `_sitemap_cache` - Cached sitemap discovery results

### Monitor Progress

```sql
SELECT * FROM _crawl_progress_crawl_results ORDER BY updated_at DESC LIMIT 1;
```

## robots.txt Compliance

The extension automatically:
1. Fetches and caches robots.txt for each domain
2. Parses Crawl-delay and Request-rate directives
3. Respects Disallow/Allow rules
4. Falls back to `User-agent: *` if no specific match
5. Discovers sitemaps from Sitemap: directives

## Error Classification

Errors are classified into types for analytics:

| Error Type | Description |
|------------|-------------|
| network_timeout | Connection or read timeout |
| network_dns_failure | DNS resolution failed |
| network_connection_refused | Connection refused |
| network_ssl_error | SSL/TLS error |
| http_client_error | 4XX status codes |
| http_server_error | 5XX status codes |
| http_rate_limited | 429 Too Many Requests |
| robots_disallowed | Blocked by robots.txt |
| content_too_large | Response exceeds max_response_bytes |
| content_type_rejected | Content-Type not accepted |

## Building from Source

```bash
git clone --recursive https://github.com/midwork-finds-jobs/duckdb-crawl.git
cd duckdb-crawl
make release GEN=ninja
```

## Testing

```bash
./build/release/duckdb -unsigned -c "
LOAD 'build/release/extension/crawler/crawler.duckdb_extension';
LOAD http_request;

CRAWL (SELECT 'https://httpbin.org/html')
INTO test_results
WITH (user_agent 'TestBot/1.0');

SELECT url, http_status, length(body) as body_len FROM test_results;
"
```

## Dependencies

- Requires the `http_request` extension for HTTP requests

## License

MIT
