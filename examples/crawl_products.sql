-- Example: Crawling E-commerce Product Pages
-- This example shows how to crawl product pages and extract pricing, availability, and details

-- Load the crawler extension
LOAD crawler;

-- Create table to store products
CREATE TABLE IF NOT EXISTS products (
    url VARCHAR PRIMARY KEY,
    sku VARCHAR,
    name VARCHAR,
    brand VARCHAR,
    price DECIMAL(10,2),
    currency VARCHAR DEFAULT 'USD',
    availability VARCHAR,
    rating DECIMAL(3,2),
    review_count INTEGER,
    image_url VARCHAR,
    description VARCHAR,
    category VARCHAR,
    crawled_at TIMESTAMP DEFAULT current_timestamp
);

-- Method 1: Extract from JSON-LD Product schema
-- Most e-commerce sites use Product schema
CRAWLING MERGE INTO products
USING (
    SELECT
        c.final_url as url,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.sku')::VARCHAR as sku,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.name')::VARCHAR as name,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.brand.name')::VARCHAR as brand,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.price')::VARCHAR
            as DECIMAL(10,2)
        ) as price,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.priceCurrency')::VARCHAR as currency,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.availability')::VARCHAR as availability,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.aggregateRating.ratingValue')::VARCHAR
            as DECIMAL(3,2)
        ) as rating,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.aggregateRating.reviewCount')::VARCHAR
            as INTEGER
        ) as review_count,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.image')::VARCHAR as image_url,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.description')::VARCHAR as description,
        jq(c.html.document, '.breadcrumb li:last-child').text as category,
        current_timestamp as crawled_at
    FROM crawl(['https://example-store.com/products']) AS listing,
    LATERAL unnest(cast(htmlpath(listing.html.document, 'a.product-card@href[*]') as VARCHAR[])) AS t(product_url),
    LATERAL crawl_url(product_url) AS c
    WHERE c.status = 200
) AS src
ON (products.url = src.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED BY TARGET THEN INSERT BY NAME
LIMIT 500;

-- Method 2: CSS-based extraction fallback
-- For sites without proper schema markup
SELECT
    c.final_url as url,
    jq(c.html.document, '[data-sku]', 'data-sku') as sku,
    jq(c.html.document, 'h1.product-title').text as name,
    jq(c.html.document, '.brand-name').text as brand,
    -- Parse price from text
    regexp_extract(jq(c.html.document, '.price').text, '[\d,.]+') as price_text,
    jq(c.html.document, '.stock-status').text as availability,
    jq(c.html.document, '.product-image img', 'src') as image_url,
    jq(c.html.document, '.product-description').text as description
FROM crawl(['https://example-store.com/product/widget-123']) AS c
WHERE c.status = 200;

-- Method 3: Using html.schema MAP for pre-parsed schemas
SELECT
    c.final_url as url,
    c.html.schema['Product'] as product_data,
    -- Handle multiple offer variants
    json_extract(c.html.schema['Product'], '$.offers') as offers
FROM crawl(['https://example-store.com/product/gadget']) AS c
WHERE c.html.schema['Product'] IS NOT NULL;

-- Price monitoring query - find price changes
WITH current_prices AS (
    SELECT
        url,
        price,
        crawled_at
    FROM products
    WHERE crawled_at = (SELECT MAX(crawled_at) FROM products p2 WHERE p2.url = products.url)
),
previous_prices AS (
    SELECT
        url,
        price,
        crawled_at
    FROM products
    WHERE crawled_at < (SELECT MAX(crawled_at) FROM products)
)
SELECT
    c.url,
    c.price as current_price,
    p.price as previous_price,
    c.price - p.price as price_change,
    round((c.price - p.price) / p.price * 100, 2) as change_percent
FROM current_prices c
JOIN previous_prices p ON c.url = p.url
WHERE c.price != p.price
ORDER BY change_percent DESC;
