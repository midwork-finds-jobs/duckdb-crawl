-- discover.sql
-- HTML Page Data Discovery Tool
--
-- Usage: Set the URL variable and run this script to discover available data
-- ./build/release/duckdb -c ".read discover.sql"

LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Set the URL to analyze
SET VARIABLE target_url = 'https://www.matsmart.fi/tuote/yumyum-pikanuudeli-kana';

-- Fetch the page
CREATE OR REPLACE TEMP TABLE page AS
SELECT * FROM crawl([getvariable('target_url')]);

-- Show fetch status
SELECT
    '=== PAGE STATUS ===' as section,
    url,
    status,
    content_type,
    response_time_ms || ' ms' as response_time,
    error
FROM page;

-- ============================================================================
-- 1. JSON-LD SCHEMA TYPES
-- ============================================================================
SELECT '=== JSON-LD SCHEMA TYPES ===' as section;

SELECT
    key as schema_type,
    json_array_length(value) as count,
    CASE
        WHEN json_array_length(value) > 0
        THEN json_extract_string(value, '$[0].name')
        ELSE NULL
    END as first_item_name
FROM page,
LATERAL (SELECT unnest(map_keys(html.schema)) as key, unnest(map_values(html.schema)) as value);

-- ============================================================================
-- 2. PRODUCT SCHEMA FIELDS (if Product exists)
-- ============================================================================
SELECT '=== PRODUCT SCHEMA FIELDS ===' as section;

SELECT
    key as field,
    typeof(value) as type,
    CASE
        WHEN typeof(value) = 'VARCHAR' THEN LEFT(value::VARCHAR, 80)
        WHEN typeof(value) = 'JSON' THEN LEFT(value::VARCHAR, 80)
        ELSE value::VARCHAR
    END as value_preview
FROM (
    SELECT unnest(json_keys(html.schema['Product'][0])) as key,
           json_extract(html.schema['Product'][0], '$.' || unnest(json_keys(html.schema['Product'][0]))) as value
    FROM page
    WHERE html.schema['Product'] IS NOT NULL
);

-- ============================================================================
-- 3. OPENGRAPH TAGS
-- ============================================================================
SELECT '=== OPENGRAPH TAGS ===' as section;

SELECT
    key as og_property,
    LEFT(value::VARCHAR, 100) as value
FROM (
    SELECT unnest(json_keys(html.opengraph)) as key,
           json_extract(html.opengraph, '$.' || unnest(json_keys(html.opengraph))) as value
    FROM page
    WHERE html.opengraph IS NOT NULL AND html.opengraph != '{}'
);

-- ============================================================================
-- 4. JAVASCRIPT VARIABLES
-- ============================================================================
SELECT '=== JAVASCRIPT VARIABLES ===' as section;

SELECT
    key as variable_name,
    typeof(value) as type,
    LEFT(value::VARCHAR, 100) as value_preview
FROM (
    SELECT unnest(json_keys(html.js)) as key,
           json_extract(html.js, '$.' || unnest(json_keys(html.js))) as value
    FROM page
    WHERE html.js IS NOT NULL AND html.js != '{}'
)
LIMIT 20;

-- ============================================================================
-- 5. READABILITY EXTRACTION
-- ============================================================================
SELECT '=== READABILITY CONTENT ===' as section;

SELECT
    key as field,
    LEFT(value::VARCHAR, 100) as value_preview
FROM (
    SELECT unnest(json_keys(html.readability)) as key,
           json_extract(html.readability, '$.' || unnest(json_keys(html.readability))) as value
    FROM page
    WHERE html.readability IS NOT NULL AND html.readability != '{}'
);

-- ============================================================================
-- 6. COMMON CSS SELECTORS TEST
-- ============================================================================
SELECT '=== CSS SELECTOR TESTS ===' as section;

SELECT * FROM (
    SELECT 'h1' as selector, jq(html.document, 'h1').text as value FROM page
    UNION ALL SELECT 'h2', jq(html.document, 'h2').text FROM page
    UNION ALL SELECT 'title', jq(html.document, 'title').text FROM page
    UNION ALL SELECT '.price', jq(html.document, '.price').text FROM page
    UNION ALL SELECT '[data-price]', jq(html.document, '[data-price]', 'data-price') FROM page
    UNION ALL SELECT '.product-name', jq(html.document, '.product-name').text FROM page
    UNION ALL SELECT '.product-title', jq(html.document, '.product-title').text FROM page
    UNION ALL SELECT '[itemprop="name"]', jq(html.document, '[itemprop="name"]').text FROM page
    UNION ALL SELECT '[itemprop="price"]', jq(html.document, '[itemprop="price"]').text FROM page
    UNION ALL SELECT 'meta[name="description"]', jq(html.document, 'meta[name="description"]', 'content') FROM page
)
WHERE value IS NOT NULL AND value != '';

-- ============================================================================
-- 7. DATA ATTRIBUTES DISCOVERY
-- ============================================================================
SELECT '=== DATA ATTRIBUTES ===' as section;

-- Extract unique data-* attribute names from HTML
WITH data_attrs AS (
    SELECT DISTINCT regexp_extract_all(html.document, 'data-([a-z0-9-]+)=', 1) as attrs
    FROM page
)
SELECT unnest(attrs) as data_attribute
FROM data_attrs
LIMIT 30;

-- ============================================================================
-- 8. DATA ATTRIBUTE VALUES
-- ============================================================================
SELECT '=== DATA ATTRIBUTE VALUES ===' as section;

SELECT * FROM (
    SELECT 'data-raw-price' as attribute,
           jq(html.document, '[data-raw-price]', 'data-raw-price') as value
    FROM page
    UNION ALL
    SELECT 'data-is-sold-out',
           jq(html.document, '[data-is-sold-out]', 'data-is-sold-out')
    FROM page
    UNION ALL
    SELECT 'data-testid="product-price"',
           jq(html.document, '[data-testid="product-price"]').text
    FROM page
    UNION ALL
    SELECT 'data-testid="product-name"',
           jq(html.document, '[data-testid="product-name"]').text
    FROM page
)
WHERE value IS NOT NULL AND value != '';

-- ============================================================================
-- 9. REGEX PATTERNS FOUND
-- ============================================================================
SELECT '=== REGEX PATTERN MATCHES ===' as section;

SELECT * FROM (
    -- Bundle count (X kpl)
    SELECT 'bundle_count' as pattern,
           regexp_extract(html.document, '([0-9]+)\s*kpl', 1) as value,
           'regexp_extract(html.document, ''([0-9]+)\s*kpl'', 1)' as sql_expression
    FROM page
    UNION ALL
    -- Price patterns
    SELECT 'price_euro',
           regexp_extract(html.document, '([0-9]+[,\.][0-9]{2})\s*€', 1),
           'regexp_extract(html.document, ''([0-9]+[,\.][0-9]{2})\s*€'', 1)'
    FROM page
    UNION ALL
    -- Date patterns (DD.MM.YYYY)
    SELECT 'date_pattern',
           regexp_extract(html.document, '([0-9]{1,2}\.[0-9]{1,2}\.[0-9]{2,4})', 1),
           'regexp_extract(html.document, ''([0-9]{1,2}\.[0-9]{1,2}\.[0-9]{2,4})'', 1)'
    FROM page
    UNION ALL
    -- Weight patterns
    SELECT 'weight_g',
           regexp_extract(html.document, '([0-9]+)\s*g(?:\s|<|")', 1),
           'regexp_extract(html.document, ''([0-9]+)\s*g(?:\s|<|")'', 1)'
    FROM page
    UNION ALL
    -- Weight patterns kg
    SELECT 'weight_kg',
           regexp_extract(html.document, '([0-9]+[,\.][0-9]+)\s*kg', 1),
           'regexp_extract(html.document, ''([0-9]+[,\.][0-9]+)\s*kg'', 1)'
    FROM page
)
WHERE value IS NOT NULL AND value != '';

-- ============================================================================
-- 9. EXAMPLE EXTRACTION QUERIES
-- ============================================================================
SELECT '=== EXAMPLE EXTRACTION QUERIES ===' as section;

SELECT
    'Product Name' as field,
    html.schema['Product'][0]->>'name' as value,
    'html.schema[''Product''][0]->>''name''' as sql_expression
FROM page WHERE html.schema['Product'] IS NOT NULL
UNION ALL
SELECT
    'Price',
    html.schema['Product'][0]->'offers'->>'price',
    'html.schema[''Product''][0]->''offers''->>''price'''
FROM page WHERE html.schema['Product'] IS NOT NULL
UNION ALL
SELECT
    'Weight',
    html.schema['Product'][0]->'weight'->>'value',
    'html.schema[''Product''][0]->''weight''->>''value'''
FROM page WHERE html.schema['Product'] IS NOT NULL
UNION ALL
SELECT
    'SKU/GTIN',
    html.schema['Product'][0]->>'sku',
    'html.schema[''Product''][0]->>''sku'''
FROM page WHERE html.schema['Product'] IS NOT NULL
UNION ALL
SELECT
    'Availability',
    html.schema['Product'][0]->'offers'->>'availability',
    'html.schema[''Product''][0]->''offers''->>''availability'''
FROM page WHERE html.schema['Product'] IS NOT NULL;

-- Cleanup
DROP TABLE page;
