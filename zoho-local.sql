-- zoho-local.sql
-- Parse Zoho career page job postings into a structured table
-- Prerequisites: Start local server with zoho-career.html in /tmp:
--   python3 -m http.server 48765 --directory /tmp

-- Load extension (json is autoloaded)
LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Crawl the local zoho career page (LIMIT is pushed down to crawler)
CRAWL (SELECT 'http://localhost:48765/zoho-career.html') INTO zoho_raw
WITH (user_agent 'TestBot/1.0') LIMIT 1;

-- Extract job postings from the js column
CREATE OR REPLACE TABLE zoho_jobs AS
WITH jobs_json AS (
    SELECT url, crawled_at, json(js->>'jobs') as jobs_array
    FROM zoho_raw
    WHERE json_valid(js->>'jobs')
)
SELECT
    job.j->>'id' as job_id,
    job.j->>'Posting_Title' as title,
    job.j->>'Poste' as position,
    job.j->>'Job_Type' as job_type,
    job.j->>'Salary' as salary,
    job.j->>'Currency' as currency,
    job.j->>'City' as city,
    job.j->>'State' as state,
    job.j->>'Country' as country,
    job.j->>'Zip_Code' as zip_code,
    (job.j->>'Remote_Job')::BOOLEAN as is_remote,
    job.j->>'Industry' as industry,
    job.j->>'Work_Experience' as experience,
    job.j->>'Date_Opened' as date_opened,
    job.j->'Langue' as languages,
    regexp_replace(job.j->>'Job_Description', '<[^>]*>', '', 'g') as description_text,
    job.j->>'Job_Description' as description_html,
    job.j->>'Required_Skills' as required_skills,
    (job.j->>'Publish')::BOOLEAN as is_published,
    jobs_json.url as source_url,
    jobs_json.crawled_at
FROM jobs_json,
LATERAL (SELECT unnest(json_extract(jobs_json.jobs_array, '$[*]')) as j) as job;

-- Show results
SELECT 'Extracted ' || COUNT(*) || ' job postings' as status FROM zoho_jobs;

SELECT
    job_id,
    title,
    job_type,
    salary,
    city || ', ' || state || ', ' || country as location,
    is_remote,
    experience,
    date_opened
FROM zoho_jobs;
