-- matsmart.sql
-- Extract product data from Matsmart.fi using new crawler syntax
--
-- Demonstrates: crawl(), jq(), html.schema, CRAWLING MERGE INTO, sitemap()

LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Configure crawler settings
SET crawler_user_agent = 'Mozilla/5.0 (compatible; PriceBot/1.0)';
SET crawler_default_delay = 1.0;
SET crawler_timeout_ms = 30000;

-- Method 1: Direct crawl with jq() extraction
-- Crawl homepage and extract product links
SELECT 'Method 1: Direct crawl with jq() extraction' as method;

CREATE OR REPLACE TABLE matsmart_products AS
SELECT
    url,
    status,
    error,
    -- Extract from JSON-LD schema (MAP returns array, [0] gets first item)
    html.schema['Product'][0]->>'sku' as sku,
    html.schema['Product'][0]->>'gtin13' as gtin,
    html.schema['Product'][0]->>'name' as name,
    html.schema['Product'][0]->>'description' as description,
    html.schema['Product'][0]->'brand'->>'name' as brand,
    -- Price: prefer data-raw-price attribute, fallback to JSON-LD
    COALESCE(
        TRY_CAST(jq(html.document, '[data-raw-price]', 'data-raw-price') AS DECIMAL(10,2)),
        TRY_CAST(html.schema['Product'][0]->'offers'->>'price' AS DECIMAL(10,2))
    ) as price,
    html.schema['Product'][0]->'offers'->>'priceCurrency' as currency,
    html.schema['Product'][0]->'offers'->>'availability' as availability,
    -- Sold out status from data attribute (more reliable than schema)
    jq(html.document, '[data-is-sold-out]', 'data-is-sold-out') = 'true' as is_sold_out,
    html.schema['Product'][0]->>'image' as image_url,
    -- Weight from JSON-LD
    html.schema['Product'][0]->'weight'->>'value' as weight,
    -- Bundle count from HTML (e.g., "3 kpl")
    TRY_CAST(regexp_extract(html.document, '([0-9]+)\s*kpl', 1) AS INTEGER) as bundle_count,
    -- Best before date (if present in HTML)
    regexp_extract(html.document, 'Parasta ennen[^0-9]*([0-9]{1,2}\.[0-9]{1,2}\.[0-9]{2,4})', 1) as best_before,
    current_timestamp as crawled_at
FROM crawl(['https://www.matsmart.fi/tuote/yumyum-pikanuudeli-kana']);

-- Debug: show raw crawl result
SELECT url, status, error FROM matsmart_products;

SELECT 'Crawled ' || COUNT(*) || ' product pages' as status FROM matsmart_products;

-- Method 2: CRAWLING MERGE INTO with sitemap discovery
SELECT 'Method 2: CRAWLING MERGE INTO with sitemap' as method;

-- Create target table if not exists
CREATE TABLE IF NOT EXISTS matsmart_catalog (
    url VARCHAR PRIMARY KEY,
    sku VARCHAR,
    gtin VARCHAR,
    name VARCHAR,
    brand VARCHAR,
    price DECIMAL(10,2),
    currency VARCHAR,
    availability VARCHAR,
    is_sold_out BOOLEAN,
    weight VARCHAR,
    bundle_count INTEGER,
    best_before VARCHAR,
    crawled_at TIMESTAMP,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

-- Upsert products - sitemap + LATERAL crawl_url() in one query
CRAWLING MERGE INTO matsmart_catalog
USING (
    SELECT
        c.url,
        c.html.schema['Product'][0]->>'sku' as sku,
        c.html.schema['Product'][0]->>'gtin13' as gtin,
        c.html.schema['Product'][0]->>'name' as name,
        c.html.schema['Product'][0]->'brand'->>'name' as brand,
        -- Price: prefer data-raw-price attribute, fallback to JSON-LD
        COALESCE(
            TRY_CAST(jq(c.html.document, '[data-raw-price]', 'data-raw-price') AS DECIMAL(10,2)),
            TRY_CAST(c.html.schema['Product'][0]->'offers'->>'price' AS DECIMAL(10,2))
        ) as price,
        c.html.schema['Product'][0]->'offers'->>'priceCurrency' as currency,
        c.html.schema['Product'][0]->'offers'->>'availability' as availability,
        jq(c.html.document, '[data-is-sold-out]', 'data-is-sold-out') = 'true' as is_sold_out,
        c.html.schema['Product'][0]->'weight'->>'value' as weight,
        TRY_CAST(regexp_extract(c.html.document, '([0-9]+)\s*kpl', 1) AS INTEGER) as bundle_count,
        regexp_extract(c.html.document, 'Parasta ennen[^0-9]*([0-9]{1,2}\.[0-9]{1,2}\.[0-9]{2,4})', 1) as best_before,
        current_timestamp as crawled_at
    FROM (
        FROM sitemap('https://www.matsmart.fi/sitemap.xml')
        WHERE url LIKE 'https://www.matsmart.fi/tuote/%'
    ) AS urls,
    LATERAL crawl_url(urls.url) AS c
    WHERE c.status = 200
) AS src
ON (src.url = matsmart_catalog.url)
WHEN MATCHED AND age(matsmart_catalog.crawled_at) > INTERVAL '24 hours' THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN UPDATE SET is_deleted = true;

-- Display results
SELECT
    sku,
    LEFT(name, 30) as name,
    printf('%.2f %s', price, COALESCE(currency, 'EUR')) as price,
    weight,
    bundle_count as qty,
    best_before,
    CASE WHEN is_sold_out THEN 'Sold Out' ELSE 'In Stock' END as status
FROM matsmart_catalog
WHERE name IS NOT NULL
ORDER BY name
LIMIT 20;

-- Price statistics
SELECT
    'Price Statistics' as report,
    COUNT(*) as total_products,
    printf('%.2f', MIN(price)) as min_price,
    printf('%.2f', AVG(price)) as avg_price,
    printf('%.2f', MAX(price)) as max_price
FROM matsmart_catalog
WHERE price IS NOT NULL;
