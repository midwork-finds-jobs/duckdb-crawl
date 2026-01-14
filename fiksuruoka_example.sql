-- Fiksuruoka product crawler example
-- Creates table and crawls product pages from sitemap

CREATE TABLE IF NOT EXISTS crawl_results (
    url VARCHAR,
    domain VARCHAR,
    http_status INTEGER,
    body VARCHAR,
    content_type VARCHAR,
    elapsed_ms INTEGER,
    crawled_at TIMESTAMP,
    error VARCHAR
);

-- Crawl all product pages from fiksuruoka.fi
-- sitemap_cache_hours caches discovered URLs for 24 hours
CRAWL SITES (SELECT 'www.fiksuruoka.fi')
INTO crawl_results
WHERE url LIKE 'https://www.fiksuruoka.fi/product/%'
WITH (
    user_agent 'FiksuruokaBot/1.0 (+https://github.com/example)',
    default_crawl_delay 0.3,
    sitemap_cache_hours 24
);
