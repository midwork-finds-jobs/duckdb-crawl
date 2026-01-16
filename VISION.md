The gap is significant. Here's the comparison:

MAPPING-THE-DATA.md vision:
SELECT
    jsonld.Product.name,
    jsonld.Product.offers.price,
    COALESCE(jsonld.Product.gtin13, microdata.Product.gtin) as gtin
FROM products;

zoho-local.sql reality:
WITH jobs_json AS (
    SELECT json(js->>'jobs') as jobs_array FROM zoho_raw
    WHERE json_valid(js->>'jobs')
)
SELECT json_extract_string(job.j, '$.id') as job_id, ...
FROM jobs_json, LATERAL (SELECT unnest(...)) as job;

Key gaps:
┌────────────────────────────────────────────┬────────────────────────────────────┐
│                   Vision                   │              Reality               │
├────────────────────────────────────────────┼────────────────────────────────────┤
│ jsonld.Product.name - schema-type indexed  │ Raw JSON string, manual extraction │
├────────────────────────────────────────────┼────────────────────────────────────┤
│ microdata.Product.gtin - microdata support │ No microdata extraction            │
├────────────────────────────────────────────┼────────────────────────────────────┤
│ css '.unit-price::text' - CSS selectors    │ No DOM extraction                  │
├────────────────────────────────────────────┼────────────────────────────────────┤
│ EXTRACT (...) clause                       │ No EXTRACT syntax                  │
├────────────────────────────────────────────┼────────────────────────────────────┤
│ Zero-config, declarative                   │ Manual SQL wrangling               │
└────────────────────────────────────────────┴────────────────────────────────────┘
Why the gap exists:

1. JSON-LD stored as raw string - not indexed by @type. Vision needs jsonld_by_type['Product'] structure
2. No microdata extractor - we have jsonld, opengraph, hydration, js but no microdata
3. No CSS selector engine - would need tree-sitter or similar DOM parser
4. No EXTRACT clause in parser - crawl_parser.cpp only handles INTO/WITH/LIMIT

The vision is a declarative schema-aware extraction DSL. Current implementation is just raw data storage + manual SQL.