# Data Extraction During Crawling: DuckDB-Native Design

## Research: What Others Have Built

### 1. **Scrapy Item Loaders** (Python) - Input/Output Processors
The most mature extraction pattern. Key insight: **separate extraction from transformation**.

```python
class Product(scrapy.Item):
    name = scrapy.Field(
        input_processor=MapCompose(remove_tags, str.strip),
        output_processor=Join()
    )
    price = scrapy.Field(
        input_processor=MapCompose(remove_tags, filter_price),
        output_processor=TakeFirst()
    )
```

**Insight**: Processors are composable pipelines. `MapCompose` chains transforms, `TakeFirst` handles arrays.

### 2. **Temme** (JavaScript) - CSS + Capture Syntax
Elegant DSL combining CSS selectors with value capture: [GitHub](https://github.com/shinima/temme)

```
li@fruits {
    span[data-color=$color]{$name};
}
```
→ `{"fruits": [{"color": "red", "name": "apple"}, ...]}`

**Insight**: `$variable` syntax for captures, `@array` for collections. Very readable.

### 3. **extruct** (Python) - Multi-Format Structured Data
Extracts ALL structured data at once: [GitHub](https://github.com/scrapinghub/extruct)

```python
data = extruct.extract(html, syntaxes=['json-ld', 'microdata', 'opengraph'])
# Returns: {'json-ld': [...], 'microdata': [...], 'opengraph': {...}}
```

**Insight**: Don't force single format—extract ALL structured data, filter later.

### 4. **duckdb_webbed** Extension - SQL-Native HTML/XML
DuckDB extension with XPath: [GitHub](https://github.com/teaguesterling/duckdb_webbed)

```sql
SELECT xml_extract_text(html, '//h1') as title,
       xml_extract_text(html, '//span[@class="price"]') as price
FROM read_html('page.html');
```

**Insight**: XPath in SQL is powerful but verbose. Needs wrapper syntax.

### 5. **htmlq/pup** - CLI Tools (jq for HTML)
Unix philosophy—pipe HTML through selectors: [htmlq](https://github.com/mgdm/htmlq)

```bash
curl example.com | htmlq '.product' --text
curl example.com | pup 'h1 text{}'
```

**Insight**: Simple single-selector queries. `text{}` suffix for content extraction.

### 6. **Zyte Automatic Extraction** - AI-Powered
No selectors needed—ML identifies Product, Article, etc: [Zyte API](https://www.zyte.com/zyte-api/ai-extraction/)

```json
{"url": "...", "product": true}
→ {"product": {"name": "...", "price": 29.99, "gtin": "..."}}
```

**Insight**: Schema.org types as first-class extraction targets. Self-healing when sites change.

### 7. **GraphQL-style** - gdom/graphql-scraper
Query HTML with GraphQL syntax: [gdom](https://github.com/syrusakbary/gdom)

```graphql
{
  page(url: "http://example.com") {
    items: query(selector: ".item") {
      title: text(selector: "h2")
      price: text(selector: ".price")
      link: attr(selector: "a", name: "href")
    }
  }
}
```

**Insight**: Nested structure mirrors output. `text()` and `attr()` as field types.

### 8. **SelectorLib** - YAML Configuration
Hierarchical YAML with type hints: [Docs](https://selectorlib.com/yaml.html)

```yaml
products:
    css: li.product
    multiple: true
    type: Text
    children:
        name:
            css: h2.title
            type: Text
        price:
            css: span.price
            type: Text
        image:
            css: img
            type: Attribute
            attribute: src
```

**Insight**: `children` for nested extraction, `multiple: true` for arrays, explicit `type`.

### 9. **Crawlee** - Request Handler Pattern
Handler receives context with extraction helpers: [Docs](https://crawlee.dev/)

```python
async def handler(context):
    await context.push_data({
        'title': context.soup.select_one('h1').text,
        'price': context.soup.select_one('.price').text,
    })
    await context.enqueue_links(selector='.pagination a')
```

**Insight**: `push_data()` streams results, `enqueue_links()` for discovery.

---

### 10. **Reader Mode / Main Content Extraction**

Safari/Firefox Reader View style extraction. Key libraries:

**[Mozilla Readability](https://github.com/mozilla/readability)** (JavaScript) - The gold standard
```javascript
const article = new Readability(document).parse();
// Returns: { title, content, textContent, length, excerpt, byline, ... }
```

**[trafilatura](https://trafilatura.readthedocs.io/)** (Python) - Best accuracy (F1=0.937)
```python
import trafilatura
text = trafilatura.extract(html)  # Clean main content
```

**Rust options**: [readability-rust](https://github.com/dreampuf/readability-rust), [fast_html2md](https://crates.io/crates/fast_html2md) with [lol_html](https://github.com/cloudflare/lol-html)

**Algorithm insight**: Score elements by text density, paragraph count, link ratio. Penalize nav/footer/sidebar patterns.

### 11. **Schema.org articleBody**

For articles, JSON-LD often contains the full text: [schema.org/articleBody](https://schema.org/articleBody)

```json
{
  "@type": "Article",
  "headline": "How to...",
  "articleBody": "The full article text content...",
  "description": "Short summary..."
}
```

| Content Type | Structured Data Field | Fallback |
|--------------|----------------------|----------|
| Article | `Article.articleBody` | Reader Mode |
| Product | `Product.description` | Meta description |
| Recipe | `Recipe.recipeInstructions` | Reader Mode |
| FAQ | `FAQPage.mainEntity[].acceptedAnswer.text` | - |

---

## Key Patterns to Adopt

| Pattern | Source | Adoption |
|---------|--------|----------|
| Type-scoped extraction | Zyte AI | `jsonld Product.name` |
| Capture syntax | Temme | `$variable` in selectors |
| Processor pipelines | Scrapy | `TRANSFORM fn1, fn2` |
| Multi-format extraction | extruct | Extract all structured data |
| Nested children | SelectorLib | `EXTRACT EACH ... AS (...)` |
| Text/attr suffixes | pup/htmlq | `::text`, `::attr(name)` |
| Unified output | extruct | Normalize to `@type`/`@context` |
| **Reader Mode** | Mozilla Readability | `main_content` column |

---

## Problem Statement

Crawling stores full HTML bodies consuming significant disk space. For grocery data, we only need ~10 fields per page. Extracting during crawl reduces storage by 95%+ while maintaining query flexibility.

**Goal**: Extract structured data (price, GTIN, stock, etc.) inline during crawl, storing only extracted fields instead of raw HTML.

## Design Principles

1. **SQL-first** - Extraction syntax should feel like native SQL
2. **Composable** - Reuse extraction logic via views, macros, or stored configs
3. **Fallback chains** - Try JSON-LD first, fall back to CSS, then regex
4. **Type-safe** - Extracted fields have DuckDB types with validation
5. **Domain-agnostic** - Same syntax works for any site, config varies

---

## Proposed Syntax: EXTRACT Clause

### Basic Form

```sql
CRAWL (SELECT url FROM product_urls) INTO products
EXTRACT (
    name        TEXT     FROM jsonld '$.name',
    price       DECIMAL  FROM jsonld '$.offers.price',
    currency    TEXT     FROM jsonld '$.offers.priceCurrency',
    gtin        TEXT     FROM jsonld '$.gtin13',
    in_stock    BOOLEAN  FROM jsonld '$.offers.availability' LIKE '%InStock%'
)
WITH (user_agent 'MyBot/1.0');
```

### With Fallback Chains

```sql
CRAWL (SELECT url FROM product_urls) INTO products
EXTRACT (
    name TEXT FROM
        jsonld '$.name'
        OR meta 'og:title'
        OR css 'h1.product-title::text'
        OR css 'h1::text',

    price DECIMAL FROM
        jsonld '$.offers.price'
        OR css '.price-current::text' TRANSFORM parse_price
        OR regex 'price["\s:]+(\d+[.,]\d+)',

    gtin TEXT FROM
        jsonld '$.gtin13'
        OR jsonld '$.gtin'
        OR attr '[data-gtin]' 'data-gtin'
        OR attr '[data-ean]' 'data-ean'
)
WITH (user_agent 'MyBot/1.0');
```

### Hierarchical Extraction Priority

```
┌─────────────────────────────────────────────────────────┐
│  TIER 1: Structured Data (Most Reliable)                │
│  ├── jsonld '$.path'        JSON-LD script blocks       │
│  ├── hydration 'key.path'   window.__NEXT_DATA__ etc    │
│  └── microdata 'itemprop'   Schema.org microdata        │
├─────────────────────────────────────────────────────────┤
│  TIER 2: Semantic HTML                                  │
│  ├── meta 'property'        <meta property="og:*">      │
│  ├── attr 'selector' 'name' data-* attributes           │
│  └── link 'rel'             <link rel="canonical">      │
├─────────────────────────────────────────────────────────┤
│  TIER 3: DOM Content                                    │
│  ├── css 'selector::text'   Text content                │
│  ├── css 'selector::html'   Inner HTML                  │
│  └── xpath '//path'         XPath expressions           │
├─────────────────────────────────────────────────────────┤
│  TIER 4: Text Patterns (Last Resort)                    │
│  └── regex 'pattern'        Regex with capture group    │
└─────────────────────────────────────────────────────────┘
```

---

## Extraction Sources

### `jsonld` - JSON-LD Structured Data

JSON-LD on real pages is complex. A single page often contains:

```html
<!-- Multiple script blocks -->
<script type="application/ld+json">{"@type": "Organization", "name": "Store Inc"}</script>
<script type="application/ld+json">{"@type": "Product", "name": "Milk 1L", ...}</script>
<script type="application/ld+json">{"@type": "BreadcrumbList", ...}</script>

<!-- Or a @graph containing everything -->
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@graph": [
    {"@type": "Organization", "name": "Store Inc"},
    {"@type": "Product", "name": "Milk 1L", "offers": {...}},
    {"@type": "BreadcrumbList", "itemListElement": [...]}
  ]
}
</script>
```

#### Type-Scoped Extraction (Recommended)

Use `Type.path` syntax to extract from specific `@type`:

```sql
-- Extract from @type="Product" only
jsonld Product.name                    -- "Milk 1L"
jsonld Product.offers.price            -- 2.99
jsonld Product.brand.name              -- "Valio"
jsonld Product.gtin13                  -- "6408430000012"

-- Extract from other types
jsonld Organization.name               -- "Store Inc"
jsonld BreadcrumbList.itemListElement  -- [{...}, {...}]

-- Nested types (Offer inside Product)
jsonld Product.offers.availability     -- "https://schema.org/InStock"
jsonld Product.aggregateRating.ratingValue  -- 4.5
```

This works regardless of whether types are in separate `<script>` blocks or inside `@graph`.

#### How Type Resolution Works

```
Page HTML
    │
    ▼
┌─────────────────────────────────────────┐
│ Find all <script type="application/ld+json">
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Parse each as JSON                      │
│ Flatten @graph arrays                   │
│ Build type index: @type → object        │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ jsonld Product.name                     │
│   → Find object where @type="Product"   │
│   → Extract .name from that object      │
└─────────────────────────────────────────┘
```

#### Real-World JSON-LD Structures

**Structure 1: Single Product object**
```json
{"@type": "Product", "name": "Milk", "offers": {"price": 2.99}}
```
→ `jsonld Product.offers.price` = 2.99

**Structure 2: @graph array**
```json
{
  "@graph": [
    {"@type": "WebPage", "name": "Product Page"},
    {"@type": "Product", "name": "Milk", "offers": {"@type": "Offer", "price": 2.99}}
  ]
}
```
→ `jsonld Product.offers.price` = 2.99 (finds Product in graph)

**Structure 3: Multiple Offers (array)**
```json
{
  "@type": "Product",
  "name": "Milk",
  "offers": [
    {"@type": "Offer", "price": 2.99, "seller": {"name": "Store A"}},
    {"@type": "Offer", "price": 3.49, "seller": {"name": "Store B"}}
  ]
}
```
→ `jsonld Product.offers[0].price` = 2.99 (first offer)
→ `jsonld Product.offers[*].price` = [2.99, 3.49] (all offers)

**Structure 4: AggregateOffer**
```json
{
  "@type": "Product",
  "offers": {
    "@type": "AggregateOffer",
    "lowPrice": 2.49,
    "highPrice": 3.99,
    "offerCount": 5
  }
}
```
→ `jsonld Product.offers.lowPrice` = 2.49

**Structure 5: Nested Organization in Product**
```json
{
  "@type": "Product",
  "brand": {"@type": "Brand", "name": "Valio"},
  "manufacturer": {"@type": "Organization", "name": "Valio Oy"}
}
```
→ `jsonld Product.brand.name` = "Valio"
→ `jsonld Product.manufacturer.name` = "Valio Oy"

#### Advanced: Type with Subtype Filter

Some pages have multiple Products (e.g., category pages with product cards):

```sql
-- Get first Product
jsonld Product[0].name

-- Get all Products as array
jsonld Product[*].name

-- Filter by property value
jsonld 'Product[?(@.gtin13)].name'      -- Only Products with GTIN
jsonld 'Product[?(@.offers.price)].name' -- Only Products with price
```

#### Handling Missing Types Gracefully

```sql
EXTRACT (
    -- Try Product first, fall back to other sources
    name TEXT FROM
        jsonld Product.name
        OR jsonld 'IndividualProduct.name'  -- Variant type
        OR jsonld 'ProductGroup.name'        -- Another variant
        OR meta 'og:title',

    -- Handle both Offer and AggregateOffer
    price DECIMAL FROM
        jsonld Product.offers.price           -- Single Offer
        OR jsonld Product.offers.lowPrice     -- AggregateOffer
        OR jsonld Product.offers[0].price     -- Array of Offers
)
```

#### Raw JSONPath (Escape Hatch)

For complex cases, use raw JSONPath with `$` prefix:

```sql
-- JSONPath filter syntax
jsonld '$..offers[?(@.availability=="https://schema.org/InStock")]'
jsonld '$["@graph"][?(@["@type"]=="Product")]'

-- Deep search (find anywhere in tree)
jsonld '$..gtin13'      -- Find gtin13 at any depth
jsonld '$..price'       -- Find any price field
```

#### Schema.org Reference

Common Product fields:
| Field | Type | Example |
|-------|------|---------|
| `name` | Text | "Organic Milk 1L" |
| `description` | Text | "Fresh organic..." |
| `sku` | Text | "MILK-001" |
| `gtin13` / `gtin` / `gtin8` | Text | "6408430000012" |
| `brand.name` | Text | "Valio" |
| `image` | URL or [URL] | "https://..." |
| `offers.price` | Number | 2.99 |
| `offers.priceCurrency` | Text | "EUR" |
| `offers.availability` | URL | "https://schema.org/InStock" |
| `aggregateRating.ratingValue` | Number | 4.5 |
| `aggregateRating.reviewCount` | Number | 128 |
| `nutrition.*` | Various | Energy, fat, etc. |

### `hydration` - JavaScript State Objects

Modern SPAs embed rich data in JavaScript variables:

```html
<script id="__NEXT_DATA__" type="application/json">
{
  "props": {
    "pageProps": {
      "product": {
        "id": 12345,
        "name": "Milk 1L",
        "price": 2.99,
        "stock": 42,           // Exact count! Not just "in stock"
        "warehouse": "Helsinki" // Internal data not shown in UI
      }
    }
  }
}
</script>
```

This data is often **richer than JSON-LD** because it's used internally.

#### Extraction Syntax

```sql
-- Next.js (most common)
hydration __NEXT_DATA__.props.pageProps.product.name
hydration __NEXT_DATA__.props.pageProps.product.price

-- Nuxt.js
hydration __NUXT__.data.product.price

-- Redux/generic
hydration __INITIAL_STATE__.products.currentProduct.name
hydration __PRELOADED_STATE__.shop.inventory

-- Google Tag Manager dataLayer (array - gets first match)
hydration dataLayer[?(@.ecommerce)].ecommerce.detail.products[0].price
```

#### Auto-Detection

The extractor automatically searches for:
1. `<script id="__NEXT_DATA__">` → Next.js
2. `window.__NUXT__` in inline scripts → Nuxt.js
3. `window.__INITIAL_STATE__` → Redux/similar
4. `window.__PRELOADED_STATE__` → Redux SSR
5. `window.dataLayer` → GTM
6. `var productData = {...}` → Custom (regex fallback)

#### Why Hydration Data is Valuable

| Source | Stock Info | Internal IDs | Real-time |
|--------|-----------|--------------|-----------|
| JSON-LD | "InStock" / "OutOfStock" | Sometimes | No |
| Hydration | `stock: 42` (exact count) | Always | Often |
| DOM | "Only 3 left!" (text) | Rarely | Sometimes |

### `meta` - Meta Tags

```sql
meta 'og:title'           -- OpenGraph
meta 'product:price:amount'
meta 'product:availability'
meta 'description'        -- Standard meta
```

### `attr` - Element Attributes

```sql
attr 'selector' 'attribute-name'

-- Examples
attr '[data-price]' 'data-price'
attr '.product' 'data-gtin'
attr 'link[rel="canonical"]' 'href'
```

### `css` - CSS Selectors

```sql
css 'selector::text'      -- Text content (trimmed)
css 'selector::html'      -- Inner HTML
css 'selector::attr(name)' -- Attribute value

-- Examples
css 'h1.product-title::text'
css '.price .amount::text'
css 'ul.ingredients li::text'  -- Returns array/list
```

### `xpath` - XPath Expressions

```sql
xpath '//h1[@class="title"]/text()'
xpath '//meta[@property="og:price"]/@content'
xpath '//script[contains(text(), "productData")]/text()'
```

### `regex` - Regular Expressions

```sql
-- First capture group is extracted
regex '"price"\s*:\s*"?(\d+[.,]?\d*)"?'
regex 'gtin["\s:]+(\d{13})'
```

### `reader` - Main Content Extraction (Reader Mode)

Safari/Firefox-style extraction of the main readable content, stripping navigation, ads, sidebars.

```sql
-- Extract main content with Reader Mode algorithm
reader content         -- Clean text content
reader html            -- Clean HTML (preserves formatting)
reader title           -- Extracted title
reader excerpt         -- First ~200 chars summary
reader byline          -- Author if detected
reader length          -- Character count of content
```

#### How Reader Mode Works

```
HTML Document
    │
    ▼
┌─────────────────────────────────────────┐
│ 1. Remove scripts, styles, hidden       │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ 2. Score each element:                  │
│    + Paragraph count                    │
│    + Text length                        │
│    + Comma count (indicates sentences)  │
│    - Link density (nav = many links)    │
│    - "sidebar", "footer", "nav" classes │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ 3. Find highest-scoring container       │
│    (usually <article> or main <div>)    │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ 4. Clean and format content             │
└─────────────────────────────────────────┘
```

#### Fallback Chain: Structured Data → Reader Mode

```sql
EXTRACT (
    -- For articles: prefer JSON-LD, fall back to Reader Mode
    content TEXT FROM
        jsonld Article.articleBody
        OR jsonld BlogPosting.articleBody
        OR jsonld NewsArticle.articleBody
        OR reader content,

    -- For products: description from structured data
    description TEXT FROM
        jsonld Product.description
        OR meta 'og:description'
        OR meta 'description'
        OR reader excerpt,

    -- Title with smart fallback
    title TEXT FROM
        jsonld '*.headline'       -- Any type with headline
        OR jsonld '*.name'
        OR meta 'og:title'
        OR reader title
        OR css 'h1::text'
)
```

#### Reader Mode for Different Page Types

| Page Type | Best Content Source | Reader Mode Useful? |
|-----------|--------------------|--------------------|
| News Article | `Article.articleBody` | ✅ Fallback |
| Blog Post | `BlogPosting.articleBody` | ✅ Fallback |
| Product Page | `Product.description` | ⚠️ May grab reviews |
| Recipe | `Recipe.recipeInstructions` | ⚠️ Use JSON-LD |
| Forum/Comments | Reader Mode | ✅ Primary |
| Documentation | Reader Mode | ✅ Primary |

#### Configuration Options

```sql
CRAWL (...) INTO pages
WITH (
    reader_mode true,              -- Enable Reader Mode extraction
    reader_min_length 500,         -- Min chars to consider readable
    reader_min_score 20,           -- Min score threshold
    reader_favor_precision true    -- Fewer false positives
);
```

---

## Transforms

Transforms normalize extracted strings into typed values.

### Built-in Transforms

```sql
EXTRACT (
    -- Price parsing: "€12,99" -> 12.99
    price DECIMAL FROM css '.price::text' TRANSFORM parse_price,

    -- Currency extraction: "€12,99" -> "EUR"
    currency TEXT FROM css '.price::text' TRANSFORM parse_currency,

    -- Quantity parsing: "500g" -> 500, "500ml" -> 500
    quantity DECIMAL FROM css '.size::text' TRANSFORM parse_quantity,

    -- Unit extraction: "500g" -> "g", "2kg" -> "kg"
    unit TEXT FROM css '.size::text' TRANSFORM parse_unit,

    -- Normalize to grams/ml: "500g" -> 500, "2kg" -> 2000
    quantity_normalized DECIMAL FROM css '.size::text' TRANSFORM normalize_quantity,

    -- Stock status: "In Stock", "Sold Out" -> boolean
    in_stock BOOLEAN FROM css '.stock::text' TRANSFORM parse_stock,

    -- Date parsing: various formats -> DATE
    best_before DATE FROM css '.expiry::text' TRANSFORM parse_date,

    -- Clean text: trim, collapse whitespace, decode entities
    description TEXT FROM css '.desc::text' TRANSFORM clean_text,

    -- Extract first number: "Rating: 4.5/5" -> 4.5
    rating DECIMAL FROM css '.rating::text' TRANSFORM extract_number,

    -- Array join: multiple elements -> comma-separated
    categories TEXT FROM css '.breadcrumb a::text' TRANSFORM join_array
)
```

### Custom Transforms via SQL Functions

```sql
-- Define custom transform as macro
CREATE MACRO parse_finnish_price(s) AS
    CAST(regexp_replace(replace(s, ',', '.'), '[^\d.]', '', 'g') AS DECIMAL);

-- Use in extraction
EXTRACT (
    price DECIMAL FROM css '.hinta::text' TRANSFORM parse_finnish_price
)
```

---

## Extraction Profiles (Reusable Configs)

### Option A: Named Profiles in SQL

```sql
-- Define profile for s-kaupat.fi
CREATE EXTRACTION PROFILE s_kaupat AS (
    name        TEXT    FROM jsonld '$.name',
    price       DECIMAL FROM jsonld '$.offers.price',
    unit_price  DECIMAL FROM css '.unit-price::text' TRANSFORM parse_price,
    gtin        TEXT    FROM jsonld '$.gtin13',
    brand       TEXT    FROM jsonld '$.brand.name',
    category    TEXT    FROM css '.breadcrumb a:last-child::text',
    in_stock    BOOLEAN FROM jsonld '$.offers.availability' LIKE '%InStock%',
    image_url   TEXT    FROM jsonld '$.image[0]'
);

-- Use profile
CRAWL (SELECT url FROM s_kaupat_urls) INTO s_kaupat_products
USING PROFILE s_kaupat
WITH (user_agent 'MyBot/1.0');
```

### Option B: Profile Tables

```sql
-- Extraction rules stored in table
CREATE TABLE extraction_profiles (
    profile_name TEXT,
    field_name TEXT,
    field_type TEXT,
    source_type TEXT,  -- jsonld, css, meta, etc
    source_path TEXT,
    transform TEXT,
    priority INT       -- Lower = try first
);

-- Define s-kaupat profile
INSERT INTO extraction_profiles VALUES
    ('s_kaupat', 'name', 'TEXT', 'jsonld', '$.name', NULL, 1),
    ('s_kaupat', 'name', 'TEXT', 'meta', 'og:title', NULL, 2),
    ('s_kaupat', 'price', 'DECIMAL', 'jsonld', '$.offers.price', NULL, 1),
    ('s_kaupat', 'price', 'DECIMAL', 'css', '.price::text', 'parse_price', 2),
    ('s_kaupat', 'gtin', 'TEXT', 'jsonld', '$.gtin13', NULL, 1);

-- Use profile by name
CRAWL (SELECT url FROM urls) INTO products
USING PROFILE 's_kaupat' FROM extraction_profiles
WITH (user_agent 'MyBot/1.0');
```

### Option C: External YAML Files

```yaml
# profiles/s-kaupat.yaml
name: s_kaupat
domain_pattern: "*.s-kaupat.fi"

fields:
  name:
    type: TEXT
    sources:
      - jsonld: $.name
      - meta: og:title
      - css: h1.product-name::text

  price:
    type: DECIMAL
    sources:
      - jsonld: $.offers.price
      - css: .product-price .amount::text
    transform: parse_price

  gtin:
    type: TEXT
    sources:
      - jsonld: $.gtin13
      - attr: "[data-ean]" ean

  ingredients:
    type: TEXT[]
    sources:
      - css: .ingredients li::text
    transform: array

  nutrition:
    type: JSON
    sources:
      - css: .nutrition-table
    transform: parse_nutrition_table
```

```sql
-- Load and use YAML profile
CRAWL (SELECT url FROM urls) INTO products
USING PROFILE 'profiles/s-kaupat.yaml'
WITH (user_agent 'MyBot/1.0');
```

---

## Output Schema Options

### Flat Schema (Default)

Each extracted field becomes a column:

```sql
CREATE TABLE products (
    url TEXT,
    crawled_at TIMESTAMP,
    http_status INT,
    name TEXT,
    price DECIMAL,
    gtin TEXT,
    in_stock BOOLEAN
);
```

### JSON Column for Flexibility

Store all extracted data in JSON, query with DuckDB's JSON functions:

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT JSON (
    name FROM jsonld '$.name',
    price FROM jsonld '$.offers.price'
)
WITH (user_agent 'MyBot/1.0');

-- Result schema:
-- url TEXT, crawled_at TIMESTAMP, extracted JSON

-- Query later:
SELECT
    url,
    extracted->>'name' as name,
    (extracted->>'price')::DECIMAL as price
FROM products;
```

### Hybrid: Core Columns + JSON Extras

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT (
    -- Typed columns for common queries
    name TEXT FROM jsonld '$.name',
    price DECIMAL FROM jsonld '$.offers.price',
    gtin TEXT FROM jsonld '$.gtin13',

    -- Everything else in JSON
    _extra JSON FROM jsonld '$' EXCLUDE [name, price, gtin]
)
```

---

## Array/List Handling

### Multiple Elements to Array

```sql
EXTRACT (
    -- Multiple matching elements -> TEXT[] array
    ingredients TEXT[] FROM css '.ingredient-list li::text',

    -- Or join to single string
    ingredients_text TEXT FROM css '.ingredient-list li::text'
        TRANSFORM join_array SEPARATOR ', ',

    -- Nested structure to JSON
    nutrition JSON FROM css '.nutrition-row' AS (
        name FROM css '.nutrient-name::text',
        value FROM css '.nutrient-value::text' TRANSFORM parse_quantity,
        unit FROM css '.nutrient-unit::text'
    )
)
```

### JSON-LD Array Access

```sql
EXTRACT (
    -- First image only
    image TEXT FROM jsonld '$.image[0]',

    -- All images as array
    images TEXT[] FROM jsonld '$.image[*]',

    -- First offer's price
    price DECIMAL FROM jsonld '$.offers[0].price'
        OR jsonld '$.offers.price'  -- Handle both array and single
)
```

---

## Conditional Extraction

### Domain-Based Rules

```sql
CRAWL (SELECT url FROM multi_domain_urls) INTO products
EXTRACT (
    name TEXT FROM
        WHEN url LIKE '%s-kaupat.fi%' THEN jsonld '$.name'
        WHEN url LIKE '%k-ruoka.fi%' THEN css '.product-title::text'
        ELSE meta 'og:title',

    price DECIMAL FROM
        WHEN url LIKE '%s-kaupat.fi%' THEN jsonld '$.offers.price'
        WHEN url LIKE '%k-ruoka.fi%' THEN css '.price-value::text' TRANSFORM parse_price
        ELSE NULL
);
```

### Content-Based Rules

```sql
EXTRACT (
    -- Only extract if page is product page
    price DECIMAL FROM jsonld '$.offers.price'
        WHERE jsonld '$["@type"]' = 'Product',

    -- Different extraction for different page types
    content TEXT FROM
        WHEN jsonld '$["@type"]' = 'Product' THEN jsonld '$.description'
        WHEN jsonld '$["@type"]' = 'Article' THEN jsonld '$.articleBody'
        ELSE css 'main::text'
)
```

---

## Error Handling

### Per-Field Error Behavior

```sql
EXTRACT (
    -- Fail crawl if name missing (required field)
    name TEXT FROM jsonld '$.name' REQUIRED,

    -- Use default if not found
    price DECIMAL FROM jsonld '$.offers.price' DEFAULT 0,

    -- NULL if not found (default behavior)
    gtin TEXT FROM jsonld '$.gtin13',

    -- Log warning if fallback used
    brand TEXT FROM
        jsonld '$.brand.name'
        OR css '.brand::text' WARN_FALLBACK
)
```

### Extraction Metadata

```sql
CRAWL (...) INTO products
EXTRACT (
    name TEXT FROM jsonld '$.name',
    price DECIMAL FROM jsonld '$.offers.price'
)
WITH (
    -- Include extraction diagnostics
    include_extraction_meta true
);

-- Result includes:
-- _extraction_meta JSON containing:
-- {
--   "name": {"source": "jsonld", "path": "$.name", "success": true},
--   "price": {"source": "jsonld", "path": "$.offers.price", "success": true}
-- }
```

---

## Complete Example: Finnish Grocery Store

```sql
-- Define reusable transforms
CREATE MACRO parse_finnish_date(s) AS
    strptime(s, '%d.%m.%Y')::DATE;

-- Crawl with full extraction
CRAWL (
    SELECT loc as url
    FROM read_csv('s-kaupat-sitemap.csv')
    WHERE loc LIKE '%/tuote/%'
)
INTO s_kaupat_products
EXTRACT (
    -- Product identity
    ean             TEXT    FROM jsonld '$.gtin13'
                                 OR attr '[data-ean]' 'data-ean',
    sku             TEXT    FROM jsonld '$.sku',
    name            TEXT    FROM jsonld '$.name'
                                 OR meta 'og:title' REQUIRED,
    brand           TEXT    FROM jsonld '$.brand.name',

    -- Pricing
    price           DECIMAL FROM jsonld '$.offers.price',
    currency        TEXT    FROM jsonld '$.offers.priceCurrency' DEFAULT 'EUR',
    unit_price      DECIMAL FROM css '.unit-price::text' TRANSFORM parse_price,
    unit_price_unit TEXT    FROM css '.unit-price-unit::text',

    -- Availability
    in_stock        BOOLEAN FROM jsonld '$.offers.availability' LIKE '%InStock%',

    -- Product details
    description     TEXT    FROM jsonld '$.description'
                                 OR css '.product-description::text',
    ingredients     TEXT    FROM css '.ingredients-list::text',
    country_origin  TEXT    FROM css '.origin-country::text',

    -- Nutrition (as JSON)
    nutrition       JSON    FROM css '.nutrition-facts'
                                 TRANSFORM parse_nutrition_table,

    -- Dates
    best_before     DATE    FROM css '.best-before::text'
                                 TRANSFORM parse_finnish_date,

    -- Media
    image_url       TEXT    FROM jsonld '$.image[0]'
                                 OR meta 'og:image',

    -- Categories
    categories      TEXT[]  FROM css '.breadcrumb a::text',

    -- Store metadata
    store_id        TEXT    FROM url REGEX '/kauppa/(\d+)/'
)
WITH (
    user_agent 'GroceryBot/1.0 (+https://example.com/bot)',
    respect_robots_txt true,
    max_crawl_pages 50000,
    default_crawl_delay 0.5
);

-- Query extracted data
SELECT
    name,
    brand,
    price,
    unit_price,
    unit_price_unit,
    nutrition->>'energy_kcal' as calories
FROM s_kaupat_products
WHERE in_stock = true
  AND price < 5.00
ORDER BY unit_price ASC;
```

---

## Implementation Considerations

### What Gets Stored

| Mode | Stored Data | Disk Usage |
|------|-------------|------------|
| No EXTRACT | url, headers, full body, metadata | ~100KB/page |
| EXTRACT JSON | url, metadata, extracted JSON | ~1KB/page |
| EXTRACT columns | url, metadata, typed columns | ~500B/page |

### Extraction Timing

```
HTTP Response
     │
     ▼
┌─────────────┐
│ Decompress  │  (gzip/brotli)
└─────────────┘
     │
     ▼
┌─────────────┐
│ Parse HTML  │  (lxml/libxml2)
└─────────────┘
     │
     ▼
┌─────────────┐
│ Extract     │  (JSON-LD, CSS, etc)
│ Fields      │
└─────────────┘
     │
     ▼
┌─────────────┐
│ Transform   │  (parse_price, etc)
└─────────────┘
     │
     ▼
┌─────────────┐
│ Validate    │  (type check, required)
└─────────────┘
     │
     ▼
┌─────────────┐
│ Batch       │  (buffer for INSERT)
│ Insert      │
└─────────────┘
```

### Library Dependencies

| Extraction Type | Library | Notes |
|----------------|---------|-------|
| HTML parsing | libxml2/lxml | Fast C-based DOM |
| CSS selectors | libxml2 + custom | Or cssselect |
| JSON-LD | rapidjson/simdjson | Already available |
| JSONPath | jsoncons or custom | Minimal subset |
| Regex | std::regex | Or RE2 for safety |

---

## Multi-Entity Extraction

Some pages contain multiple entities (category pages, search results, product listings).

### Extract All Products from Category Page

```sql
CRAWL (SELECT url FROM category_urls) INTO category_products
EXTRACT EACH jsonld Product[*] AS (
    -- Each Product becomes a row
    name        TEXT    FROM .name,
    price       DECIMAL FROM .offers.price OR .offers.lowPrice,
    gtin        TEXT    FROM .gtin13,
    url         TEXT    FROM .url,
    image       TEXT    FROM .image[0] OR .image
)
WITH (user_agent 'Bot/1.0');

-- Result: One row per Product found, not per page
-- source_url | name | price | gtin | url | image
```

### Combine Page-Level and Item-Level Data

```sql
CRAWL (SELECT url FROM category_urls) INTO category_products
EXTRACT (
    -- Page-level fields (once per page)
    page_url      TEXT FROM url,
    category_name TEXT FROM jsonld BreadcrumbList.itemListElement[-1].name,
    store_name    TEXT FROM jsonld Organization.name,

    -- Item-level fields (array, one per product on page)
    products JSON[] FROM jsonld Product[*] AS (
        name  FROM .name,
        price FROM .offers.price,
        gtin  FROM .gtin13
    )
);

-- Or flatten to one row per product:
EXTRACT EACH jsonld Product[*] AS (...)
INCLUDE (
    -- These page-level fields are repeated for each product row
    page_url      TEXT FROM url,
    category_name TEXT FROM jsonld BreadcrumbList.itemListElement[-1].name
)
```

### Extract from CSS-Selected Repeating Elements

```sql
-- Category page with product cards in DOM
CRAWL (SELECT url FROM category_urls) INTO products
EXTRACT EACH css '.product-card' AS (
    name  TEXT    FROM css '.product-name::text',
    price DECIMAL FROM css '.product-price::text' TRANSFORM parse_price,
    url   TEXT    FROM css 'a::attr(href)',
    image TEXT    FROM css 'img::attr(src)'
);
```

---

## Storing Raw Structured Data

Sometimes you want to extract fields AND keep the full structured data for later analysis.

### Store JSON-LD as Column

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT (
    -- Typed columns for fast queries
    name  TEXT    FROM jsonld Product.name,
    price DECIMAL FROM jsonld Product.offers.price,

    -- Keep full Product JSON-LD for later
    _jsonld_product JSON FROM jsonld Product,

    -- Keep ALL JSON-LD from page
    _jsonld_all JSON FROM jsonld *
);

-- Later, extract more fields without re-crawling:
SELECT
    name,
    price,
    _jsonld_product->>'aggregateRating'->>'ratingValue' as rating,
    _jsonld_product->>'nutrition'->>'calories' as calories
FROM products;
```

### Store Hydration Data

```sql
EXTRACT (
    price DECIMAL FROM hydration __NEXT_DATA__.props.pageProps.product.price,

    -- Keep full product object from Next.js
    _hydration JSON FROM hydration __NEXT_DATA__.props.pageProps.product
);
```

### Hybrid: Minimal Crawl + Rich Post-Processing

```sql
-- Phase 1: Fast crawl, store only structured data (small)
CRAWL (SELECT url FROM urls) INTO raw_data
EXTRACT (
    _product JSON FROM jsonld Product,
    _hydration JSON FROM hydration __NEXT_DATA__.props.pageProps.product
)
WITH (user_agent 'Bot/1.0');

-- Phase 2: Extract fields in SQL (no network, instant)
CREATE TABLE products AS
SELECT
    url,
    crawled_at,
    COALESCE(
        _product->>'name',
        _hydration->>'name'
    ) as name,
    COALESCE(
        (_product->'offers'->>'price')::DECIMAL,
        (_hydration->>'price')::DECIMAL
    ) as price,
    _product->>'gtin13' as gtin
FROM raw_data;
```

---

## Alternative: Post-Crawl Extraction

If inline extraction is too complex, use DuckDB's JSON functions post-crawl:

```sql
-- Crawl storing JSON-LD only (much smaller than full HTML)
CRAWL (SELECT url FROM urls) INTO raw_pages
WITH (extract_jsonld true, store_body false);

-- Extract in SQL
CREATE VIEW products AS
SELECT
    url,
    crawled_at,
    jsonld->>'$.name' as name,
    (jsonld->>'$.offers.price')::DECIMAL as price,
    jsonld->>'$.gtin13' as gtin,
    jsonld->>'$.offers.availability' LIKE '%InStock%' as in_stock
FROM raw_pages
WHERE jsonld->>'$["@type"]' = 'Product';
```

This is simpler but requires storing JSON-LD (still ~90% smaller than HTML).

---

## Summary

**Recommended Approach**: EXTRACT clause with type-scoped JSON-LD and fallback chains

```sql
CRAWL (source_query) INTO target_table
EXTRACT (
    field TYPE FROM jsonld Type.path [OR source 'path' ...] [TRANSFORM func] [DEFAULT val]
)
WITH (options);
```

**Key Syntax Elements**:

| Element | Example | Purpose |
|---------|---------|---------|
| Type-scoped JSON-LD | `jsonld Product.name` | Extract from specific @type |
| Fallback chain | `OR meta 'og:title' OR css 'h1::text'` | Try sources in order |
| Transform | `TRANSFORM parse_price` | Normalize extracted value |
| Multi-entity | `EXTRACT EACH jsonld Product[*]` | One row per entity |
| Raw storage | `FROM jsonld Product` (no path) | Keep full JSON for later |

**Storage Options**:

| Mode | Stored Data | Size/page |
|------|-------------|-----------|
| No EXTRACT | Full HTML body | ~100KB |
| EXTRACT columns | Typed fields only | ~500B |
| EXTRACT + raw JSON | Fields + _jsonld JSON | ~2KB |

**DX Benefits**:
- Readable: extraction logic visible in SQL
- Debuggable: test JSON-LD paths in browser console
- Maintainable: change selectors without recompiling
- Composable: profiles can inherit/extend
- Flexible: store raw JSON for future field extraction

---

## Alternative Syntax Proposals

Based on the research, here are refined syntax options:

### Option A: Temme-Inspired Capture Syntax

Inspired by [Temme](https://github.com/shinima/temme)'s `$variable` captures:

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT '
    Product@product {
        name: $.name,
        price: $.offers.price,
        gtin: $.gtin13
    }
    .product-card@fallback {
        name: h1::text,
        price: .price::text | parse_price,
        image: img::src
    }
'
WITH (user_agent 'Bot/1.0');
```

**Pros**: Very concise, mirrors output structure
**Cons**: New DSL to learn, harder to validate

### Option B: extruct-Style Auto-Extract + SQL Filter

Inspired by [extruct](https://github.com/scrapinghub/extruct)'s "extract everything" approach:

```sql
-- Phase 1: Auto-extract ALL structured data
CRAWL (SELECT url FROM urls) INTO raw_pages
EXTRACT STRUCTURED  -- Extracts json-ld, microdata, opengraph, hydration
WITH (user_agent 'Bot/1.0');

-- Phase 2: Filter in pure SQL (DuckDB strengths!)
CREATE VIEW products AS
SELECT
    url,
    structured.jsonld.Product.name as name,
    structured.jsonld.Product.offers.price as price,
    COALESCE(
        structured.jsonld.Product.gtin13,
        structured.microdata.Product.gtin
    ) as gtin,
    structured.opengraph.image as image
FROM raw_pages
WHERE structured.jsonld.Product IS NOT NULL;
```

**Pros**: Leverages DuckDB's JSON powers, no new DSL, flexible post-processing
**Cons**: Requires storing intermediate JSON (but much smaller than HTML)

### Option C: GraphQL-Style Nested Query

Inspired by [gdom](https://github.com/syrusakbary/gdom):

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT {
    product: jsonld(type: "Product") {
        name
        price: offers.price
        gtin: gtin13
        brand: brand.name
        rating: aggregateRating {
            value: ratingValue
            count: reviewCount
        }
    }
    fallback: css(".product-page") {
        name: text("h1")
        price: text(".price") | parse_price
        image: attr("img.main", "src")
    }
}
WITH (user_agent 'Bot/1.0');
```

**Pros**: Familiar to GraphQL users, explicit nesting
**Cons**: Verbose, new syntax

### Option D: dbt-Style Macros + Profiles

Inspired by [dbt](https://getdbt.com)'s composable transformations:

```sql
-- Define reusable extraction macros
CREATE EXTRACTION MACRO product_from_jsonld AS
    jsonld Product {
        name,
        price: offers.price,
        gtin: gtin13
    };

CREATE EXTRACTION MACRO product_from_dom AS
    css .product-page {
        name: h1::text,
        price: .price::text | parse_price
    };

-- Compose macros in profile
CREATE EXTRACTION PROFILE grocery_product AS (
    FIRST_OF(product_from_jsonld, product_from_dom)
);

-- Use profile
CRAWL (SELECT url FROM urls) INTO products
USING PROFILE grocery_product;
```

**Pros**: Maximum reusability, testable components
**Cons**: Complex setup

### Option E: SQL Functions (duckdb_webbed Style)

Extend [duckdb_webbed](https://github.com/teaguesterling/duckdb_webbed) approach:

```sql
CRAWL (SELECT url FROM urls) INTO products
EXTRACT (
    name        TEXT    AS COALESCE(
                            jsonld_value(body, 'Product.name'),
                            meta_value(body, 'og:title'),
                            css_text(body, 'h1.title')
                        ),
    price       DECIMAL AS parse_price(COALESCE(
                            jsonld_value(body, 'Product.offers.price'),
                            css_text(body, '.price')
                        )),
    gtin        TEXT    AS jsonld_value(body, 'Product.gtin13'),
    _raw_jsonld JSON    AS jsonld_extract(body, 'Product')
)
WITH (user_agent 'Bot/1.0');
```

**Pros**: Pure SQL, familiar to DuckDB users, composable
**Cons**: Verbose, repetitive COALESCE patterns

---

## Recommended Hybrid Approach

Combine the best ideas:

### 1. Auto-Extract Structured Data (extruct-style)

```sql
-- Always extract structured data by default
CRAWL (...) INTO pages
WITH (
    extract_structured true,  -- Default: extract json-ld, microdata, og
    store_body false          -- Don't store HTML
);

-- Result columns:
-- url, crawled_at, status, jsonld JSON, microdata JSON, opengraph JSON
```

### 2. Type-Scoped Accessors (Zyte-style)

```sql
-- Access by Schema.org type
SELECT
    jsonld.Product.name,           -- Direct path
    jsonld.Product.offers.price,
    jsonld.Organization.name as store_name
FROM pages;
```

### 3. Fallback Chains with COALESCE

```sql
SELECT
    COALESCE(
        jsonld.Product.name,
        opengraph.title,
        microdata.Product.name
    ) as name
FROM pages;
```

### 4. Custom Field Extraction (Optional)

For DOM scraping when structured data is missing:

```sql
CRAWL (...) INTO pages
EXTRACT CUSTOM (
    legacy_price DECIMAL FROM css '.old-price::text' TRANSFORM parse_price
)
WITH (extract_structured true);
```

### 5. Profiles for Multi-Site

```sql
CREATE EXTRACTION PROFILE s_kaupat AS (
    STRUCTURED,  -- Auto-extract json-ld etc
    CUSTOM (
        unit_price FROM css '.yksikkohinta::text' TRANSFORM parse_price,
        best_before FROM css '.parasta-ennen::text' TRANSFORM parse_date
    )
);

CRAWL (...) INTO products USING PROFILE s_kaupat;
```

---

## Final Syntax Recommendation

```sql
-- Simple case: auto-extract structured data
CRAWL (SELECT url FROM urls) INTO pages
WITH (user_agent 'Bot/1.0');

-- Auto-generated columns:
-- url, crawled_at, http_status, content_type,
-- jsonld JSON,        -- All JSON-LD by @type: {"Product": {...}, "Org": {...}}
-- opengraph JSON,     -- OpenGraph meta tags: {title, image, description, ...}
-- hydration JSON      -- __NEXT_DATA__, dataLayer, etc
```

### Query Examples

```sql
-- Products from JSON-LD
SELECT
    url,
    jsonld->'Product'->>'name' as name,
    (jsonld->'Product'->'offers'->>'price')::DECIMAL as price,
    jsonld->'Product'->>'gtin13' as gtin
FROM pages
WHERE jsonld->'Product' IS NOT NULL;

-- Articles from JSON-LD
SELECT
    url,
    COALESCE(
        jsonld->'Article'->>'headline',
        jsonld->'BlogPosting'->>'headline',
        opengraph->>'title'
    ) as title,
    COALESCE(
        jsonld->'Article'->>'articleBody',
        jsonld->'BlogPosting'->>'articleBody',
        jsonld->'Article'->>'description'
    ) as content
FROM pages
WHERE jsonld->'Article' IS NOT NULL
   OR jsonld->'BlogPosting' IS NOT NULL;

-- OpenGraph data for social sharing
SELECT
    url,
    opengraph->>'title' as og_title,
    opengraph->>'image' as og_image,
    opengraph->>'description' as og_description
FROM pages;

-- Next.js hydration data (often richer than JSON-LD)
SELECT
    url,
    hydration->'__NEXT_DATA__'->'props'->'pageProps'->'product'->>'name' as name,
    (hydration->'__NEXT_DATA__'->'props'->'pageProps'->'product'->>'stock')::INT as stock_count
FROM pages
WHERE hydration->'__NEXT_DATA__' IS NOT NULL;
```

### Custom Field Extraction

```sql
-- Add site-specific fields not in structured data
CRAWL (SELECT url FROM urls) INTO products
EXTRACT (
    unit_price DECIMAL FROM css '.unit-price::text' | parse_price,
    stock_count INT FROM hydration '__NEXT_DATA__.props.product.stock',
    ingredients TEXT FROM css '.ingredients-list::text'
)
WITH (user_agent 'Bot/1.0');

-- Result: url, jsonld, opengraph, hydration, unit_price, stock_count, ingredients
```

### Disable Unused Extractors

```sql
-- Only extract what you need
CRAWL (...) INTO products
WITH (
    extract_jsonld true,       -- Default: true
    extract_opengraph true,    -- Default: true
    extract_hydration true     -- Default: true
    -- extract_microdata false -- Not yet implemented
);
```

**Why this approach?**
1. **Zero config for common case** - structured data auto-extracted
2. **DuckDB-native querying** - use familiar `->` and `->>` JSON operators
3. **Escape hatch** - EXTRACT clause for custom DOM fields
4. **Small storage** - JSON columns ~2-5KB vs HTML ~100KB
5. **Flexible post-processing** - refine extraction in SQL views

---

## Unresolved Questions

1. **Auto-extract scope**: Enable all by default, or opt-in? (Recommend: all on, disable via WITH)
2. **JSON column structure**: Single `jsonld` with type keys, or separate `jsonld_product`, `jsonld_article`?
3. **Type conflicts**: Two Products on same page → array `[Product1, Product2]` or first match?
4. **Hydration detection**: Auto-detect `__NEXT_DATA__`, `__NUXT__`, etc? (Recommend: yes)
5. **Transform syntax**: Pipe `| parse_price` or keyword `TRANSFORM parse_price`? (Recommend: pipe)
6. **Testing tool**: `EXPLAIN EXTRACT` to preview extraction on sample URL?
7. **Body storage**: Store HTML body by default or only when explicitly requested?

---

## Implementation Notes

### Phase 1: Core Extractors (C++)

| Extractor | Library | Complexity | Priority |
|-----------|---------|------------|----------|
| JSON-LD | rapidjson (already have) | Low | ✅ First |
| OpenGraph | libxml2 XPath | Low | ✅ Second |
| Hydration | Regex patterns | Low | ✅ Third |
| Microdata | libxml2 XPath | Medium | Later |
| CSS Selectors | libxml2 + custom | Medium | Later |
| Reader Mode | Separate plugin | - | TODO |

### Phase 2: Parser Extension

Extend `crawl_parser.cpp` to support:
```
CRAWL (query) INTO table
[EXTRACT (field TYPE FROM source ...)]
WITH (options)
```

### Phase 3: Table Schema

Auto-create table with columns:
```sql
CREATE TABLE pages (
    url TEXT,
    crawled_at TIMESTAMP,
    http_status INT,
    content_type TEXT,
    -- Auto-extracted structured data
    jsonld JSON,           -- JSON-LD by @type: {"Product": {...}, "Organization": {...}}
    opengraph JSON,        -- {title, description, image, url, type, ...}
    hydration JSON,        -- {__NEXT_DATA__: {...}, dataLayer: [...], ...}
    -- Later: microdata JSON
    -- Later: reader JSON (via separate plugin)
    -- Custom EXTRACT fields appended here
);
```

### Reader Mode: Separate Plugin (TODO)

> **TODO**: Build Reader Mode as a separate DuckDB extension (`duckdb-readability`) that provides:
> ```sql
> SELECT readability_extract(html) as reader FROM pages;
> -- Returns: {title, content, excerpt, byline, length}
> ```
>
> This crawler extension can then optionally call it if loaded:
> ```sql
> CRAWL (...) INTO pages WITH (extract_reader true);
> -- Only works if duckdb-readability extension is loaded
> ```
>
> Benefits:
> - Separation of concerns
> - Can use Rust FFI ([readability-rust](https://github.com/dreampuf/readability-rust)) without complicating this extension
> - Users who don't need Reader Mode don't pay the cost
> - Can be developed/tested independently

**Skipping Reader Mode for initial implementation. Focus on JSON-LD, OpenGraph, Microdata, Hydration.**
