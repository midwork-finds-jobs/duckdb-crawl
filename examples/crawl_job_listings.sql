-- Example: Crawling Job Listings
-- This example shows how to crawl job listing pages and extract structured data
-- using CRAWLING MERGE INTO for incremental updates

-- Load the crawler extension
LOAD crawler;

-- Create table to store job listings
CREATE TABLE IF NOT EXISTS job_listings (
    url VARCHAR PRIMARY KEY,
    title VARCHAR,
    company VARCHAR,
    location VARCHAR,
    salary VARCHAR,
    description_text VARCHAR,
    posted_at TIMESTAMP,
    crawled_at TIMESTAMP DEFAULT current_timestamp,
    is_deleted BOOLEAN DEFAULT false
);

-- Method 1: Using htmlpath() with JSON-LD schema
-- Many job boards use JSON-LD structured data
CRAWLING MERGE INTO job_listings
USING (
    SELECT
        c.final_url as url,
        -- Extract from JSON-LD if available
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.title')::VARCHAR as title,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.hiringOrganization.name')::VARCHAR as company,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.jobLocation.address.addressLocality')::VARCHAR as location,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.baseSalary.value.value')::VARCHAR as salary,
        -- Fallback to CSS selectors for description
        jq(c.html.document, '.job-description').text as description_text,
        try_cast(htmlpath(c.html.document, 'script[type="application/ld+json"]@text.datePosted')::VARCHAR as TIMESTAMP) as posted_at,
        current_timestamp as crawled_at,
        false as is_deleted
    FROM crawl(['https://example.com/jobs']) AS listing,
    -- Extract job URLs from listing page
    LATERAL unnest(cast(htmlpath(listing.html.document, 'a.job-link@href[*]') as VARCHAR[])) AS t(job_url),
    -- Crawl each job page
    LATERAL crawl_url(job_url) AS c
    WHERE c.status = 200
) AS src
ON (job_listings.url = src.url)
WHEN MATCHED AND age(job_listings.crawled_at) > INTERVAL '24 hours' THEN UPDATE BY NAME
WHEN NOT MATCHED BY TARGET THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE AND is_deleted = false THEN UPDATE SET is_deleted = true
LIMIT 100;

-- Method 2: Using jq() for CSS-based extraction
-- For sites without JSON-LD, use CSS selectors
SELECT
    c.final_url as url,
    jq(c.html.document, 'h1.job-title').text as title,
    jq(c.html.document, '.company-name').text as company,
    jq(c.html.document, '.location').text as location,
    jq(c.html.document, '.salary-range').text as salary,
    jq(c.html.document, '.job-description').text as description,
    -- Extract data attributes
    jq(c.html.document, '[data-job-id]', 'data-job-id') as job_id
FROM crawl(['https://example.com/jobs/123']) AS c
WHERE c.status = 200;

-- Method 3: Using html.schema for pre-extracted structured data
-- The crawler automatically extracts JSON-LD, OpenGraph, and microdata
SELECT
    c.final_url as url,
    c.html.schema['JobPosting'] as job_schema,
    -- Access specific fields from schema MAP
    json_extract_string(c.html.schema['JobPosting'], '$.title') as title,
    json_extract_string(c.html.schema['JobPosting'], '$.hiringOrganization.name') as company
FROM crawl(['https://example.com/jobs/456']) AS c
WHERE c.status = 200
  AND c.html.schema['JobPosting'] IS NOT NULL;

-- Query the results
SELECT url, title, company, location, is_deleted
FROM job_listings
WHERE is_deleted = false
ORDER BY crawled_at DESC;
