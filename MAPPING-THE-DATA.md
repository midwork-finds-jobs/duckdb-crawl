I need to build a service which tracks consumer prices for products for the government to build models on inflation and help consumers.

There are sadly no APIs of how to use that data and there are hundreds of grocery chains.

What are the typical maintainable ways to do this for hundreds of sites?

Many parts of the data is available in ld+json format but most of it is in the html itself. It's important to also track if the SKU is in stock because the price doesn't mean anything if one can't order or pre-order the products.

We then in the end want to help comparing same products eg cucumber per kg from shop A to a cucumber from shop B.

Explore and find good maintainable examples of how could we structure the code that maps the html into this extracted format per unique website.

We have already collected the html pages and now it's just a problem of matching that html into this extracted format. How should code like this look like? What are the best practices currently used elsewhere?

Focus only on the problem of mapping from the html to machine readable data.

```sql
-- Zero-config: auto-extracts json-ld, microdata, opengraph
CRAWL (SELECT url FROM urls) INTO products
WITH (user_agent 'Bot/1.0');

-- Query with DuckDB's JSON operators
SELECT
    jsonld.Product.name,
    jsonld.Product.offers.price,
    COALESCE(jsonld.Product.gtin13, microdata.Product.gtin) as gtin
FROM products;

-- Escape hatch for custom DOM extraction
CRAWL (...) INTO products
EXTRACT (
    jsonld.Product.name,
    COALESCE(jsonld.Product.gtin13, microdata.Product.gtin) as gtin
    unit_price DECIMAL FROM css '.unit-price::text' | parse_price
);
```