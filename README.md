# DuckDB Crawler Extension

A high-performance web crawler extension for DuckDB that fetches web pages, extracts structured data from HTML, and stores results directly in database tables.

## Features

- **Native SQL syntax** - `CRAWL` statement integrates seamlessly with DuckDB
- **HTTP/1.1, HTTP/2** support via reqwest (Rust)
- **Parallel crawling** with configurable thread pools
- **robots.txt compliance** with crawl delay respect
- **Sitemap discovery** and parsing (XML, gzip)
- **Structured data extraction**:
  - JSON-LD (with @graph support)
  - Microdata (schema.org HTML attributes)
  - OpenGraph meta tags
  - CSS selectors
  - JavaScript variables (AST-based via tree-sitter)
- **EXTRACT clause** - Pull specific fields during crawl
- **Predicate pushdown** - Filter URLs before fetching
- **Rate limiting** per domain with adaptive backoff
- **Link following** with depth control

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CRAWL Statement                         │
│  CRAWL (SELECT urls) INTO table EXTRACT (...) WHERE ... WITH   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DuckDB Parser Extension                      │
│  Parses CRAWL/INTO/EXTRACT/WHERE/WITH into execution plan      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Crawler Thread Pool                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Worker 1 │  │ Worker 2 │  │ Worker 3 │  │ Worker N │       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│       │             │             │             │              │
│       ▼             ▼             ▼             ▼              │
│  ┌─────────────────────────────────────────────────────┐      │
│  │              reqwest (HTTP Client)                   │      │
│  │    HTTP/1.1 · HTTP/2 · TLS · Keep-Alive             │      │
│  │    Connection pooling · Compression · Redirects     │      │
│  └─────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   HTML Parser (Rust FFI)                        │
│  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌─────────────┐    │
│  │  JSON-LD  │ │ Microdata │ │    CSS    │ │ JS Variables│    │
│  │ (yyjson)  │ │ (scraper) │ │ (scraper) │ │(tree-sitter)│    │
│  └───────────┘ └───────────┘ └───────────┘ └─────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      EXTRACT Evaluation                         │
│  Dot notation · COALESCE · Type coercion · Transforms          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        DuckDB Table                             │
│  url | status | body | jsonld | microdata | extracted_* | ...  │
└─────────────────────────────────────────────────────────────────┘
```

## How It Works

### 1. URL Discovery

The crawler starts with seed URLs from the subquery:

```sql
CRAWL (SELECT 'https://example.com/sitemap.xml')  -- Direct URLs
CRAWL (SELECT url FROM my_urls)                    -- From table
CRAWL (SELECT 'example.com')                       -- Auto-discover sitemap
```

If `follow_links` is enabled, it parses HTML for `<a href>` links and adds them to the queue, respecting `max_crawl_depth` and same-domain rules.

### 2. HTTP Fetching (reqwest)

Each URL is fetched using reqwest with:

- **Connection pooling** - Reuses TCP connections for same hosts
- **Keep-alive** - Maintains persistent connections
- **HTTP/2 multiplexing** - Multiple requests over single connection
- **Automatic decompression** - gzip, deflate, brotli
- **Redirect following** - Configurable limit
- **TLS verification** - Certificate validation
- **Timeout handling** - Connect and read timeouts

### 3. HTML Parsing (Rust)

The Rust HTML parser processes each response:

**JSON-LD Extraction:**
- Finds all `<script type="application/ld+json">` tags
- Parses JSON content with error tolerance
- Handles `@graph` arrays (multiple objects)
- Indexes results by `@type` for easy access

**Microdata Extraction:**
- Traverses DOM for `itemscope` attributes
- Builds nested objects from `itemprop` values
- Handles nested itemscopes (e.g., Product > Offer)
- Extracts values from appropriate HTML attributes

**CSS Selector Extraction:**
- Uses `scraper` crate (built on `html5ever`)
- Supports full CSS3 selectors
- Extracts text, attributes, or HTML content

**JavaScript Variable Extraction:**
- Uses `tree-sitter` to build AST of script contents
- Extracts `var`/`let`/`const` declarations
- Captures `window.X = {...}` assignments
- Parses object/array literal values to JSON

### 4. EXTRACT Evaluation

EXTRACT expressions are evaluated against parsed data:

```sql
EXTRACT (
    jsonld.Product.name,                    -- Dot notation path
    COALESCE(jsonld.gtin, microdata.gtin),  -- First non-null
    price DECIMAL FROM css '.price' | parse_price  -- CSS + transform
)
```

- **Path traversal** - Navigates nested JSON structures
- **COALESCE** - Tries sources in order until non-null found
- **Transforms** - String processing (trim, parse_price, etc.)
- **Type coercion** - Converts to DECIMAL, INTEGER, BOOLEAN

### 5. Storage

Results are batch-inserted into the target DuckDB table:

- Table created automatically if not exists
- Schema includes standard columns + EXTRACT aliases
- Efficient batch inserts (configurable batch size)
- Transaction per batch for consistency

## Installation

```bash
# Build from source (requires Rust toolchain)
git clone https://github.com/user/duckdb-crawler
cd duckdb-crawler
./vcpkg/bootstrap-vcpkg.sh
make release VCPKG_TOOLCHAIN_PATH=$(pwd)/vcpkg/scripts/buildsystems/vcpkg.cmake

# Load in DuckDB
LOAD 'build/release/extension/crawler/crawler.duckdb_extension';
```

## Quick Start

```sql
LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Simple crawl
CRAWL (SELECT 'https://example.com/')
INTO pages
WITH (max_crawl_pages 10);

-- View results
SELECT url, status_code, length(body) as size FROM pages;
```

## Table Functions

### crawl_url() - LATERAL Join Support

Use `crawl_url()` for row-by-row crawling with LATERAL joins:

```sql
-- Crawl URLs from a table
SELECT
    seed.category,
    c.url,
    c.status_code,
    c.html.readability.title
FROM seed_urls seed,
LATERAL crawl_url(seed.url) AS c
WHERE c.status_code = 200;

-- Chain with extraction
SELECT
    c.final_url,
    jq(c.body, 'h1').text as title,
    c.html.schema['Product'] as product_data
FROM urls_to_check u,
LATERAL crawl_url(u.link) AS c;
```

### sitemap() - Sitemap Parsing

Parse XML sitemaps (supports gzip, recursive sitemap indexes):

```sql
-- Get all URLs from sitemap
SELECT * FROM sitemap('https://example.com/sitemap.xml');

-- Recursive sitemap discovery
SELECT url, lastmod, priority
FROM sitemap('https://example.com/sitemap_index.xml', recursive := true);
```

## Extraction Functions

### jq() - CSS Selector Extraction

Extract data using CSS selectors. Returns a STRUCT with text, html, and attr fields:

```sql
-- Basic usage: returns STRUCT(text, html, attr MAP)
SELECT jq('<div class="price">$19.99</div>', 'div.price').text;
-- Result: '$19.99'

-- Get inner HTML
SELECT jq('<div><span>Hello</span></div>', 'div').html;
-- Result: '<span>Hello</span>'

-- Get attribute
SELECT jq('<a href="/link" title="Click">Text</a>', 'a').attr['href'];
-- Result: '/link'

-- 3-argument form: get specific attribute directly
SELECT jq('<img src="pic.jpg" alt="Photo">', 'img', 'src');
-- Result: 'pic.jpg'
```

### htmlpath() - JSON Path + CSS Extraction

Combine CSS selectors with JSON-like path syntax:

```sql
-- Extract text content (use @text suffix)
SELECT htmlpath('<h1>Title</h1>', 'h1@text');
-- Result: "Title"

-- Extract attribute (use @attr_name suffix)
SELECT htmlpath('<a href="/page">Link</a>', 'a@href');
-- Result: "/page"

-- Extract from JSON-LD
SELECT htmlpath(body, 'script[type="application/ld+json"]@text.Product.name')
FROM pages WHERE status_code = 200;

-- Extract multiple elements (returns JSON array)
SELECT htmlpath(body, 'a.product@href[*]') FROM pages;
```

## HTML Structured Data

Crawl results include pre-extracted structured data:

### html.readability - Article Extraction

Mozilla Readability-style content extraction:

```sql
SELECT
    url,
    html.readability.title,        -- Extracted article title
    html.readability.excerpt,      -- Short summary
    html.readability.text_content, -- Plain text content
    html.readability.content       -- Cleaned HTML content
FROM crawl(['https://example.com/article']);
```

### html.schema - Schema.org Data

JSON-LD and Microdata as MAP(VARCHAR, JSON):

```sql
SELECT
    url,
    html.schema['Product'] as product,        -- Product schema
    html.schema['Organization'] as org,       -- Organization schema
    html.schema['BreadcrumbList'] as breadcrumbs
FROM crawl(['https://example.com/product/123']);

-- Access nested fields
SELECT
    html.schema['Product']->>'name' as name,
    html.schema['Product']->'offers'->>'price' as price
FROM crawl(['https://shop.example.com/item']);
```

## CRAWLING MERGE INTO

Upsert crawl results with MERGE semantics. Supports conditional updates and handling of stale rows:

```sql
-- Basic upsert: update existing, insert new
CRAWLING MERGE INTO products
USING (
    SELECT * FROM crawl(['https://shop.example.com/products'])
) AS src
ON (src.url = products.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME;

-- Conditional update: only update stale rows (>24 hours old)
CRAWLING MERGE INTO jobs
USING (
    SELECT
        c.final_url as url,
        jq(c.body, 'h1.title').text as title,
        current_timestamp as crawled_at
    FROM crawl(['https://jobs.example.com/listings']) AS listing,
    LATERAL unnest(cast(htmlpath(listing.body, 'a.job@href[*]') as VARCHAR[])) AS t(job_url),
    LATERAL crawl_url(job_url) AS c
    WHERE c.status_code = 200
) AS src
ON (src.url = jobs.url)
WHEN MATCHED AND age(jobs.crawled_at) > INTERVAL '24 hours' THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
LIMIT 100;

-- Handle rows no longer in source (soft delete)
CRAWLING MERGE INTO listings
USING (SELECT * FROM crawl([...]) WHERE status = 200) AS src
ON (src.url = listings.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN UPDATE SET is_deleted = true;

-- Hard delete rows not in source
CRAWLING MERGE INTO listings
USING (...) AS src
ON (src.url = listings.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED BY SOURCE AND is_archived = false THEN DELETE;
```

### MERGE Clauses

| Clause | Description |
|--------|-------------|
| `WHEN MATCHED THEN UPDATE BY NAME` | Update existing rows, match columns by name |
| `WHEN MATCHED THEN DELETE` | Delete matched rows |
| `WHEN MATCHED AND <condition>` | Conditional match (e.g., stale check) |
| `WHEN NOT MATCHED THEN INSERT BY NAME` | Insert new rows |
| `WHEN NOT MATCHED BY SOURCE THEN UPDATE SET ...` | Soft-delete rows no longer in source |
| `WHEN NOT MATCHED BY SOURCE THEN DELETE` | Hard-delete rows no longer in source |
| `WHEN NOT MATCHED BY SOURCE AND <condition>` | Conditional handling of missing rows |

## Global Settings

Configure crawler defaults with `SET` statements:

```sql
-- Set default user agent
SET crawler_user_agent = 'MyBot/1.0 (+https://example.com/bot)';

-- Set default delay between requests (seconds)
SET crawler_default_delay = 1.0;

-- Respect robots.txt (default: true)
SET crawler_respect_robots = true;

-- Request timeout (milliseconds)
SET crawler_timeout_ms = 30000;

-- Maximum response size (bytes)
SET crawler_max_response_bytes = 10485760;  -- 10MB
```

### Available Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `crawler_user_agent` | VARCHAR | required | HTTP User-Agent header |
| `crawler_default_delay` | DOUBLE | 1.0 | Delay between requests (seconds) |
| `crawler_respect_robots` | BOOLEAN | true | Honor robots.txt |
| `crawler_timeout_ms` | INTEGER | 30000 | Request timeout |
| `crawler_max_response_bytes` | INTEGER | 10485760 | Max response size |

## Proxy Support

### Via DuckDB HTTP Settings

```sql
-- Set proxy via DuckDB's built-in settings
SET http_proxy = 'http://proxy.example.com:8080';
SET http_proxy_username = 'user';
SET http_proxy_password = 'pass';
```

### Via CREATE SECRET

```sql
-- Create secret for API authentication
CREATE SECRET my_api (
    TYPE HTTP,
    EXTRA_HTTP_HEADERS MAP {
        'Authorization': 'Bearer sk-xxxx',
        'X-Custom-Header': 'value'
    }
);

-- Crawler automatically uses secrets matching URL patterns
```

## Example SQL Files

See the `examples/` directory for complete working examples:

| File | Description |
|------|-------------|
| `examples/crawl_job_listings.sql` | Job board scraping with schema.org |
| `examples/crawl_products.sql` | E-commerce price monitoring |
| `examples/crawl_blog_posts.sql` | Blog article extraction with readability |
| `examples/crawl_events.sql` | Event page crawling with Event schema |

## CRAWL Statement Syntax

```sql
CRAWL (subquery)
INTO table_name
[EXTRACT (extraction_specs)]
[WHERE url_filter]
[WITH (options)]
[LIMIT n]
```

### Components

| Clause | Required | Description |
|--------|----------|-------------|
| `CRAWL (subquery)` | Yes | Source URLs - any SELECT returning URL strings |
| `INTO table_name` | Yes | Target table (created if not exists) |
| `EXTRACT (...)` | No | Fields to extract from HTML |
| `WHERE condition` | No | URL filter applied before fetching |
| `WITH (options)` | No | Crawler configuration |
| `LIMIT n` | No | Maximum pages to crawl |

## EXTRACT Syntax

The EXTRACT clause specifies structured data to pull from HTML pages during crawling. This eliminates the need for post-processing queries.

### Basic Syntax

```sql
EXTRACT (
    source.path as alias,
    source.path.to.nested.field,
    COALESCE(source1.path, source2.path) as fallback_field,
    alias TYPE FROM source 'selector' | transform
)
```

### Data Sources

| Source | Description | Example |
|--------|-------------|---------|
| `jsonld` | JSON-LD from `<script type="application/ld+json">` | `jsonld.Product.name` |
| `microdata` | Schema.org from `itemscope`/`itemprop` | `microdata.Product.gtin` |
| `og` | OpenGraph meta tags | `og.title`, `og.image` |
| `meta` | Standard meta tags | `meta.description` |
| `js` | JavaScript variables | `js.siteConfig.price` |
| `css` | CSS selector extraction | `css '.price::text'` |

### Dot Notation

Access nested JSON fields using dots:

```sql
EXTRACT (
    -- Simple field
    jsonld.Product.name,

    -- Nested objects
    jsonld.Product.offers.price,
    jsonld.Product.brand.name,

    -- From different sources
    microdata.Product.gtin,
    og.title,
    og.image,
    meta.description
)
```

### Array Access

Access array elements with bracket notation:

```sql
EXTRACT (
    jsonld.Product.image[0] as main_image,
    jsonld.Product.offers[0].price as first_price,
    jsonld.ItemList.itemListElement[0].item.name as first_item
)
```

### COALESCE - Fallback Values

Try multiple sources, use first non-null value:

```sql
EXTRACT (
    -- Try JSON-LD first, fall back to microdata
    COALESCE(jsonld.Product.gtin13, jsonld.Product.gtin, microdata.Product.gtin) as gtin,

    -- Try structured data, fall back to meta tags
    COALESCE(jsonld.Product.name, og.title, meta.title) as name,

    -- Mix sources freely
    COALESCE(jsonld.Product.offers.price, microdata.Offer.price, js.productPrice) as price
)
```

### CSS Selectors

Extract content using CSS selectors with pseudo-elements:

```sql
EXTRACT (
    -- Text content
    css '.product-title::text' as title,
    css 'h1.name::text' as heading,

    -- Attribute values
    css 'img.product::attr(src)' as image_url,
    css 'a.buy-button::attr(href)' as buy_link,

    -- Outer HTML (default)
    css 'div.description' as description_html
)
```

**Pseudo-elements:**
| Pseudo | Description |
|--------|-------------|
| `::text` | Extract text content (strips HTML tags) |
| `::attr(name)` | Extract attribute value |
| (none) | Extract outer HTML |

### Typed Extraction

Specify output type with optional transform:

```sql
EXTRACT (
    -- Type coercion
    price DECIMAL FROM jsonld.Product.offers.price,
    quantity INTEGER FROM css '.qty::text',
    in_stock BOOLEAN FROM jsonld.Product.offers.availability,

    -- Type + transform
    price DECIMAL FROM css '.price::text' | parse_price,
    name VARCHAR FROM jsonld.Product.name | trim
)
```

**Supported Types:**
| Type | Description |
|------|-------------|
| `VARCHAR` | String (default) |
| `DECIMAL` / `DOUBLE` / `FLOAT` | Numeric with decimals |
| `INTEGER` / `BIGINT` / `INT` | Whole numbers |
| `BOOLEAN` / `BOOL` | true/false |

### Transforms

Apply transformations to extracted values:

```sql
EXTRACT (
    -- Whitespace handling
    jsonld.Product.name | trim as name,

    -- Price parsing: "€12.99" → "12.99"
    price DECIMAL FROM css '.price::text' | parse_price,

    -- Case conversion
    jsonld.Product.sku | uppercase as sku,
    og.title | lowercase as title_lower,

    -- HTML stripping
    jsonld.Product.description | strip_html as description
)
```

**Available Transforms:**
| Transform | Description | Example |
|-----------|-------------|---------|
| `trim` | Remove leading/trailing whitespace | `"  hello  "` → `"hello"` |
| `parse_price` | Extract numeric from price string | `"€12,99"` → `"12.99"` |
| `lowercase` | Convert to lowercase | `"Hello"` → `"hello"` |
| `uppercase` | Convert to uppercase | `"Hello"` → `"HELLO"` |
| `strip_html` | Remove HTML tags | `"<b>Hi</b>"` → `"Hi"` |

### Type Coercion Details

**DECIMAL/DOUBLE/FLOAT:**
- Extracts digits and decimal point
- Handles negative numbers
- `"€12.99"` → `12.99`
- `"-5.5"` → `-5.5`

**INTEGER/BIGINT:**
- Extracts digits only
- Handles negative numbers
- `"42 items"` → `42`
- `"-10"` → `-10`

**BOOLEAN:**
- Recognizes: `true`, `false`, `yes`, `no`, `1`, `0`, `on`, `off`
- Case-insensitive
- Returns empty string for invalid values

## WITH Options

```sql
WITH (
    -- Required
    user_agent 'MyBot/1.0 (+https://example.com/bot)',

    -- HTTP settings
    timeout_seconds 30,
    max_retries 3,
    compress true,

    -- Crawl behavior
    follow_links true,
    max_crawl_depth 3,
    max_crawl_pages 1000,
    allow_subdomains false,

    -- Rate limiting
    default_crawl_delay 1.0,
    min_crawl_delay 0.5,
    max_crawl_delay 60.0,
    max_parallel_per_domain 4,

    -- Content filtering
    accept_content_types 'text/html,application/xhtml+xml',
    reject_content_types 'application/pdf',
    max_response_bytes 10485760,

    -- robots.txt
    respect_robots_txt true,

    -- Extraction
    extract_js true
)
```

### Option Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `user_agent` | string | required | HTTP User-Agent header |
| `timeout_seconds` | int | 30 | Request timeout |
| `max_retries` | int | 3 | Retry failed requests |
| `compress` | bool | true | Request gzip/deflate |
| `follow_links` | bool | false | Discover linked pages |
| `max_crawl_depth` | int | 10 | Maximum link depth |
| `max_crawl_pages` | int | 10000 | Maximum pages to crawl |
| `allow_subdomains` | bool | false | Follow subdomain links |
| `default_crawl_delay` | float | 1.0 | Delay between requests (seconds) |
| `min_crawl_delay` | float | 0.0 | Minimum delay floor |
| `max_crawl_delay` | float | 60.0 | Maximum delay cap |
| `max_parallel_per_domain` | int | 8 | Concurrent requests per domain |
| `max_total_connections` | int | 32 | Global connection limit |
| `accept_content_types` | string | '' | Whitelist content types |
| `reject_content_types` | string | '' | Blacklist content types |
| `max_response_bytes` | int | 10MB | Maximum response size |
| `respect_robots_txt` | bool | true | Honor robots.txt |
| `respect_nofollow` | bool | true | Skip rel=nofollow links |
| `extract_js` | bool | false | Extract JS variables |
| `sitemap_cache_hours` | float | 24.0 | Sitemap cache duration |

## Output Schema

The output table contains standard columns plus EXTRACT aliases:

| Column | Type | Description |
|--------|------|-------------|
| `url` | VARCHAR | Fetched URL |
| `surt_key` | VARCHAR | SURT-normalized URL (Common Crawl format) |
| `status_code` | INTEGER | HTTP status code |
| `body` | VARCHAR | Response body |
| `content_type` | VARCHAR | Content-Type header |
| `crawled_at` | TIMESTAMP | Fetch timestamp |
| `elapsed_ms` | BIGINT | Request duration |
| `error` | VARCHAR | Error message if failed |
| `error_type` | VARCHAR | Classified error type |
| `final_url` | VARCHAR | URL after redirects |
| `redirect_count` | INTEGER | Number of redirects |
| `etag` | VARCHAR | ETag header |
| `last_modified` | VARCHAR | Last-Modified header |
| `content_hash` | VARCHAR | SHA-256 of body |
| `jsonld` | JSON | Full JSON-LD data |
| `opengraph` | JSON | Full OpenGraph data |
| `meta` | JSON | Full meta tags |
| `js` | JSON | Full JS variables |
| `<alias>` | VARCHAR | EXTRACT columns |

## Examples

### E-commerce Product Scraping

```sql
CRAWL (SELECT 'https://shop.example.com/sitemap.xml')
INTO products
EXTRACT (
    jsonld.Product.sku,
    jsonld.Product.name | trim as name,
    COALESCE(jsonld.Product.gtin13, microdata.Product.gtin) as gtin,
    jsonld.Product.brand.name as brand,
    price DECIMAL FROM jsonld.Product.offers.price,
    jsonld.Product.offers.priceCurrency as currency,
    jsonld.Product.offers.availability as stock_status,
    jsonld.Product.image[0] as image
)
WHERE url LIKE '%/product/%'
WITH (
    user_agent 'PriceBot/1.0 (+https://mysite.com/bot)',
    default_crawl_delay 0.5,
    max_crawl_pages 5000
);

-- Analyze results
SELECT
    brand,
    COUNT(*) as products,
    printf('%.2f', AVG(price)) as avg_price
FROM products
WHERE price IS NOT NULL
GROUP BY brand
ORDER BY products DESC;
```

### News Article Extraction

```sql
CRAWL (SELECT 'https://news.example.com/')
INTO articles
EXTRACT (
    jsonld.NewsArticle.headline as title,
    jsonld.NewsArticle.datePublished as published,
    jsonld.NewsArticle.author.name as author,
    og.description as summary,
    css 'article.content p::text' | trim as first_paragraph
)
WHERE url LIKE '%/article/%'
WITH (
    user_agent 'NewsBot/1.0',
    follow_links true,
    max_crawl_depth 2,
    max_crawl_pages 500
);
```

### Finnish Grocery Store (Matsmart)

```sql
CRAWL (SELECT 'https://www.matsmart.fi/')
INTO matsmart_products
EXTRACT (
    COALESCE(jsonld.Product.sku, microdata.Product.sku) as sku,
    COALESCE(jsonld.Product.gtin, jsonld.Product.gtin13) as gtin,
    jsonld.Product.name as name,
    jsonld.Product.brand.name as brand,
    price DECIMAL FROM jsonld.Product.offers.price,
    jsonld.Product.offers.priceCurrency as currency,
    jsonld.Product.offers.availability as availability,
    unit_price VARCHAR FROM css '.unit-price::text' | trim,
    jsonld.Product.image[0] as image_url
)
WHERE url LIKE 'https://www.matsmart.fi/tuote/%'
WITH (
    user_agent 'Mozilla/5.0 (compatible; PriceBot/1.0)',
    follow_links true,
    max_crawl_depth 3,
    crawl_delay_ms 500
)
LIMIT 100;
```

### Price Monitoring Over Time

```sql
-- Create monitoring table
CREATE TABLE IF NOT EXISTS price_history (
    sku VARCHAR,
    price DECIMAL,
    in_stock BOOLEAN,
    checked_at TIMESTAMP
);

-- Crawl and append prices
INSERT INTO price_history
SELECT
    sku,
    price::DECIMAL,
    availability LIKE '%InStock%' as in_stock,
    crawled_at as checked_at
FROM (
    CRAWL (SELECT url FROM monitored_products)
    INTO _tmp_prices
    EXTRACT (
        jsonld.Product.sku as sku,
        jsonld.Product.offers.price as price,
        jsonld.Product.offers.availability as availability
    )
    WITH (user_agent 'PriceMonitor/1.0', timeout_seconds 15)
);

-- Detect price changes
SELECT
    sku,
    price,
    LAG(price) OVER (PARTITION BY sku ORDER BY checked_at) as prev_price,
    price - LAG(price) OVER (PARTITION BY sku ORDER BY checked_at) as change
FROM price_history
WHERE change != 0;
```

## Error Handling

Errors are classified for easy filtering:

| Error Type | Description |
|------------|-------------|
| `network_timeout` | Connection or read timeout |
| `network_dns_failure` | DNS resolution failed |
| `network_connection_refused` | Connection refused |
| `network_ssl_error` | SSL/TLS error |
| `http_client_error` | 4XX status codes |
| `http_server_error` | 5XX status codes |
| `http_rate_limited` | 429 Too Many Requests |
| `robots_disallowed` | Blocked by robots.txt |
| `content_too_large` | Response exceeds limit |
| `content_type_rejected` | Content-Type filtered |

```sql
-- Retry failed URLs
CRAWL (
    SELECT url FROM my_crawl
    WHERE error_type = 'network_timeout'
)
INTO my_crawl_retry
WITH (user_agent 'MyBot/1.0', timeout_seconds 60);
```

## Performance

- **Parallel fetching**: Configurable thread pool
- **Connection reuse**: reqwest connection pooling
- **HTTP/2 multiplexing**: Multiple requests per connection
- **Streaming parsing**: HTML parsed incrementally
- **Batch inserts**: Efficient database writes
- **Predicate pushdown**: URL filters skip unwanted pages

Typical throughput: **50-200 pages/second** depending on:
- Network latency to target sites
- Target server response times
- Crawl delay settings
- Page sizes

## Limitations

- JavaScript rendering not supported (static HTML only)
- Maximum response size: 10MB default (configurable)
- Cookies not persisted across requests
- Single database connection

## Dependencies

Built with:
- **reqwest** - HTTP client (Rust, HTTP/1.1, HTTP/2, TLS)
- **scraper** - HTML parsing (Rust, CSS selectors)
- **yyjson** - JSON parsing (C++)
- **readability** - Article extraction (Rust)

## License

MIT
