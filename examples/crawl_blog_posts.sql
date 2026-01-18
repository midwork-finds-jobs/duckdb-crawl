-- Example: Crawling Blog Posts with Readability
-- This example shows how to crawl blog posts and extract clean content

-- Load the crawler extension
LOAD crawler;

-- Create table to store blog posts
CREATE TABLE IF NOT EXISTS blog_posts (
    url VARCHAR PRIMARY KEY,
    title VARCHAR,
    author VARCHAR,
    published_at TIMESTAMP,
    updated_at TIMESTAMP,
    excerpt VARCHAR,
    content_text VARCHAR,
    content_html VARCHAR,
    word_count INTEGER,
    reading_time_minutes INTEGER,
    tags VARCHAR[],
    image_url VARCHAR,
    crawled_at TIMESTAMP DEFAULT current_timestamp
);

-- Method 1: Use html.readability for clean article extraction
-- The crawler automatically extracts article content using Mozilla Readability
CRAWLING MERGE INTO blog_posts
USING (
    SELECT
        c.final_url as url,
        -- Readability-extracted title (often cleaner than page title)
        c.html.readability.title as title,
        -- OpenGraph/meta author
        coalesce(
            htmlpath(c.html.document, 'meta[name="author"]@content')::VARCHAR,
            htmlpath(c.html.document, 'script[type="application/ld+json"]@text.author.name')::VARCHAR
        ) as author,
        -- Parse dates
        try_cast(
            coalesce(
                htmlpath(c.html.document, 'meta[property="article:published_time"]@content')::VARCHAR,
                htmlpath(c.html.document, 'script[type="application/ld+json"]@text.datePublished')::VARCHAR,
                jq(c.html.document, 'time[datetime]', 'datetime')
            ) as TIMESTAMP
        ) as published_at,
        try_cast(
            htmlpath(c.html.document, 'meta[property="article:modified_time"]@content')::VARCHAR
            as TIMESTAMP
        ) as updated_at,
        -- Readability excerpt (clean text preview)
        c.html.readability.excerpt as excerpt,
        -- Clean text content (no HTML)
        c.html.readability.text_content as content_text,
        -- HTML content for display
        c.html.readability.content as content_html,
        -- Calculate word count from clean text
        array_length(string_split(c.html.readability.text_content, ' ')) as word_count,
        -- Estimate reading time (200 words per minute)
        greatest(1, array_length(string_split(c.html.readability.text_content, ' ')) / 200) as reading_time_minutes,
        -- Extract tags from meta or JSON-LD
        string_split(
            htmlpath(c.html.document, 'meta[name="keywords"]@content')::VARCHAR,
            ','
        ) as tags,
        -- Featured image
        coalesce(
            htmlpath(c.html.document, 'meta[property="og:image"]@content')::VARCHAR,
            jq(c.html.document, 'article img:first-child', 'src')
        ) as image_url,
        current_timestamp as crawled_at
    FROM crawl(['https://example-blog.com/sitemap.xml'], sitemap := true) AS c
    WHERE c.status = 200
      AND c.content_type LIKE 'text/html%'
      -- Only include actual articles (filter out category pages, etc)
      AND c.html.readability.text_content IS NOT NULL
      AND length(c.html.readability.text_content) > 500
) AS src
ON (blog_posts.url = src.url)
WHEN MATCHED AND age(blog_posts.crawled_at) > INTERVAL '7 days' THEN UPDATE BY NAME
WHEN NOT MATCHED BY TARGET THEN INSERT BY NAME
LIMIT 200;

-- Method 2: Manual extraction with jq()
-- For sites where readability doesn't work well
SELECT
    c.final_url as url,
    jq(c.html.document, 'h1.post-title').text as title,
    jq(c.html.document, '.author-name').text as author,
    jq(c.html.document, '.post-content').text as content_text,
    jq(c.html.document, '.post-content').html as content_html
FROM crawl(['https://example-blog.com/post/hello-world']) AS c
WHERE c.status = 200;

-- Method 3: Using Article schema
SELECT
    c.final_url as url,
    json_extract_string(c.html.schema['Article'], '$.headline') as title,
    json_extract_string(c.html.schema['Article'], '$.author.name') as author,
    json_extract_string(c.html.schema['Article'], '$.datePublished') as published,
    json_extract_string(c.html.schema['Article'], '$.description') as description
FROM crawl(['https://example-blog.com/article']) AS c
WHERE c.html.schema['Article'] IS NOT NULL;

-- Query for recent posts with good content
SELECT
    url,
    title,
    author,
    published_at,
    word_count,
    reading_time_minutes || ' min read' as reading_time,
    left(excerpt, 150) || '...' as preview
FROM blog_posts
WHERE published_at > current_date - INTERVAL '30 days'
  AND word_count > 300
ORDER BY published_at DESC
LIMIT 20;

-- Find most prolific authors
SELECT
    author,
    count(*) as post_count,
    avg(word_count)::INTEGER as avg_words,
    min(published_at) as first_post,
    max(published_at) as latest_post
FROM blog_posts
WHERE author IS NOT NULL
GROUP BY author
ORDER BY post_count DESC;
