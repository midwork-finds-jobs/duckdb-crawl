-- Example: Crawling Event Listings
-- This example shows how to crawl event pages and extract dates, venues, and ticket info

-- Load the crawler extension
LOAD crawler;

-- Create table to store events
CREATE TABLE IF NOT EXISTS events (
    url VARCHAR PRIMARY KEY,
    name VARCHAR,
    description VARCHAR,
    start_date TIMESTAMP,
    end_date TIMESTAMP,
    venue_name VARCHAR,
    venue_address VARCHAR,
    venue_city VARCHAR,
    venue_country VARCHAR,
    organizer VARCHAR,
    ticket_url VARCHAR,
    price_min DECIMAL(10,2),
    price_max DECIMAL(10,2),
    currency VARCHAR DEFAULT 'USD',
    availability VARCHAR,
    image_url VARCHAR,
    event_type VARCHAR,
    is_online BOOLEAN DEFAULT false,
    crawled_at TIMESTAMP DEFAULT current_timestamp
);

-- Method 1: Extract from Event schema (JSON-LD)
-- Event platforms typically use Event or MusicEvent schema
CRAWLING MERGE INTO events
USING (
    SELECT
        c.final_url as url,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.name')::VARCHAR as name,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.description')::VARCHAR as description,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.startDate')::VARCHAR
            as TIMESTAMP
        ) as start_date,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.endDate')::VARCHAR
            as TIMESTAMP
        ) as end_date,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.location.name')::VARCHAR as venue_name,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.location.address.streetAddress')::VARCHAR as venue_address,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.location.address.addressLocality')::VARCHAR as venue_city,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.location.address.addressCountry')::VARCHAR as venue_country,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.organizer.name')::VARCHAR as organizer,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.url')::VARCHAR as ticket_url,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.lowPrice')::VARCHAR
            as DECIMAL(10,2)
        ) as price_min,
        try_cast(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.highPrice')::VARCHAR
            as DECIMAL(10,2)
        ) as price_max,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.priceCurrency')::VARCHAR as currency,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.offers.availability')::VARCHAR as availability,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.image')::VARCHAR as image_url,
        htmlpath(c.html.document, 'script[type="application/ld+json"]@text.@type')::VARCHAR as event_type,
        coalesce(
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.eventAttendanceMode')::VARCHAR,
            ''
        ) LIKE '%Online%' as is_online,
        current_timestamp as crawled_at
    FROM crawl(['https://example-events.com/events']) AS listing,
    LATERAL unnest(cast(htmlpath(listing.html.document, 'a.event-card@href[*]') as VARCHAR[])) AS t(event_url),
    LATERAL crawl_url(event_url) AS c
    WHERE c.status = 200
) AS src
ON (events.url = src.url)
WHEN MATCHED THEN UPDATE BY NAME
WHEN NOT MATCHED BY TARGET THEN INSERT BY NAME
LIMIT 200;

-- Method 2: CSS-based extraction for sites without schema
SELECT
    c.final_url as url,
    jq(c.html.document, 'h1.event-name').text as name,
    jq(c.html.document, '.event-description').text as description,
    -- Parse date/time from various formats
    jq(c.html.document, '.event-date', 'datetime') as date_attr,
    jq(c.html.document, '.event-date').text as date_text,
    jq(c.html.document, '.venue-name').text as venue_name,
    jq(c.html.document, '.venue-address').text as venue_address,
    -- Extract ticket price
    regexp_extract(jq(c.html.document, '.ticket-price').text, '[\d,.]+') as price,
    jq(c.html.document, 'a.buy-tickets', 'href') as ticket_url
FROM crawl(['https://example-events.com/event/concert-123']) AS c
WHERE c.status = 200;

-- Method 3: Using html.schema for Event types
SELECT
    c.final_url as url,
    -- Event schema is often stored under 'Event' or specific types like 'MusicEvent'
    coalesce(
        c.html.schema['Event'],
        c.html.schema['MusicEvent'],
        c.html.schema['BusinessEvent'],
        c.html.schema['SportsEvent']
    ) as event_data
FROM crawl(['https://example-events.com/event/456']) AS c
WHERE c.html.schema['Event'] IS NOT NULL
   OR c.html.schema['MusicEvent'] IS NOT NULL;

-- Upcoming events query
SELECT
    name,
    start_date,
    venue_name,
    venue_city,
    CASE
        WHEN is_online THEN 'Online'
        ELSE venue_city
    END as location,
    coalesce(price_min::VARCHAR || ' - ' || price_max::VARCHAR || ' ' || currency, 'Free') as price_range
FROM events
WHERE start_date >= current_timestamp
  AND (availability IS NULL OR availability NOT LIKE '%SoldOut%')
ORDER BY start_date ASC
LIMIT 50;

-- Events by city
SELECT
    venue_city as city,
    count(*) as event_count,
    min(start_date) as next_event,
    avg(price_min)::DECIMAL(10,2) as avg_min_price
FROM events
WHERE start_date >= current_timestamp
  AND venue_city IS NOT NULL
  AND NOT is_online
GROUP BY venue_city
ORDER BY event_count DESC;

-- Online events
SELECT
    name,
    start_date,
    organizer,
    ticket_url
FROM events
WHERE is_online = true
  AND start_date >= current_timestamp
ORDER BY start_date ASC;
