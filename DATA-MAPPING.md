# **Scalable Architecture for High-Volume Grocery Data Extraction: Standardization, Normalization, and Maintainability**

## **1. Executive Overview**

The engineering challenge of aggregating pricing and inventory data from hundreds of grocery chains is fundamentally distinct from small-scale web scraping. While a single script can effectively monitor a local supermarket, scaling to hundreds of domains—each with unique Document Object Model (DOM) structures, varying anti-bot defenses, and frequent frontend deployments—requires a paradigm shift from imperative scripting to a declarative, platform-based architecture. The primary bottleneck at this scale ceases to be network throughput or storage; rather, it becomes the cognitive load and engineering hours required to maintain thousands of fragile extraction selectors against a constantly shifting web landscape.1

This report outlines a comprehensive reference architecture for a high-volume grocery data extraction system. The proposed solution prioritizes **maintainability** and **data homogeneity** over raw speed. It advocates for an Event-Driven Architecture (EDA) that strictly decouples the acquisition of raw HTML (crawling) from the interpretation of that HTML (extraction). This separation allow for the implementation of a "Time Machine" capability, where historical data can be re-processed with improved logic without necessitating expensive re-crawls.3

Furthermore, the report details a hierarchical parsing strategy that moves beyond brittle CSS selectors. By prioritizing semantic metadata (JSON-LD, Schema.org) and implementing robust fallback mechanisms, the system can achieve high availability even during site redesigns. Finally, it addresses the critical downstream challenge of **semantic normalization**—transforming raw strings like "£2.50 / 3pk" into strictly typed, normalized machine-readable entities using advanced Python libraries such as price-parser, Quantulum3, and Pint.5 This ensures that the resulting dataset is not merely a collection of text strings, but a structured analytical asset capable of powering precise price comparison and inventory forecasting models.

## **2. Architectural Pillars for Scalable Extraction**

When architecting a system to monitor hundreds of retailers, the "Monolithic Spider" pattern—where crawling, parsing, and saving occur in a single synchronous loop—is a catastrophic anti-pattern. Such systems are brittle; a single exception in parsing can halt the collection of data, and fixing a bug requires re-running the entire expensive network operation. Enterprise-grade scraping systems must be composed of distributed, independent microservices coordinated via asynchronous task queues.8

### **2.1 Decoupling Crawl and Extraction Layers**

The most critical architectural decision is the strict separation of the **Crawl Layer** (I/O bound) from the **Extraction Layer** (CPU bound). This follows the "Extract, Load, Transform" (ELT) pattern rather than the traditional ETL, treating the raw HTML as an immutable artifact that is stored immediately upon retrieval.4

#### **The Crawl Service**

The responsibility of the Crawl Service is singular: fetching the content of a URL and storing it reliably. It handles the complexity of HTTP transport, including proxy rotation, user-agent spoofing, TLS fingerprinting, and retry logic (exponential backoff).1 Critically, the Crawl Service *does not parse* the HTML. It treats the response body as a binary blob.

Upon a successful fetch, the Crawl Service persists two distinct artifacts to a Data Lake (e.g., Amazon S3, Google Cloud Storage, or MinIO):

1. **Raw HTML:** The exact byte stream returned by the server.
2. **Metadata JSON:** A sidecar file containing headers, status codes, timestamps, and the effective URL (after redirects).

This "Raw Storage" approach is the bedrock of maintainability.1 If the extraction logic for *Tesco* contains a bug that misses a new discount field, the engineer can fix the parser and re-run it against the stored HTML from the last month. In a coupled system, that historical discount data would be lost forever.

#### **The Extraction Service**

The Extraction Service operates downstream, triggered by "New File" events in the Data Lake or messages in a queue (e.g., Kafka, RabbitMQ).9 This service fetches the HTML from storage and applies the relevant parsing rules. Because it performs no network I/O, it is highly CPU-efficient and can process thousands of pages per second in parallel.11

This architecture enables **hermetic development**. Developers can build and test extraction logic locally using saved HTML files without ever triggering an anti-bot ban or waiting for network requests. It transforms the scraping problem from a network engineering problem into a pure data transformation problem.

### **2.2 Distributed Task Orchestration**

Managing the schedule for hundreds of sites—some requiring hourly updates, others daily—requires a robust orchestrator. Hard-coded cron jobs are insufficient for this scale because they lack visibility and backpressure management.

A Distributed Task Queue (e.g., Celery with Redis, or specific orchestration tools like Airflow or Kestra) is recommended.8 The orchestrator creates "Scrape Jobs" which are pushed to a priority queue.

- **High Priority:** Price monitoring for volatile items (e.g., fresh produce).
- **Low Priority:** Weekly discovery crawls for new product URLs.

This decoupling allows for horizontal scaling. During "Black Friday" or other peak times, additional worker nodes can be spun up to consume the queue faster without code changes.8 The architecture must support **idempotency**: if a worker crashes mid-scrape, the job should be re-queued and re-processed without creating duplicate data or corrupted states.1

### **2.3 The "Generic Spider" Pattern**

Maintaining 500 individual Python files (e.g., spiders/walmart.py, spiders/kroger.py) leads to massive code duplication and "spaghetti code." As the number of sites grows, the maintenance burden of updating common logic (e.g., changing how logging works) becomes untenable.

The industry best practice for this scale is the **Generic Spider** or **Configuration-Driven Scraper**.13 In this model, the codebase contains only one single "Spider" class. This spider is agnostic to the specific site it is visiting. Instead, it loads a **Configuration File** (YAML or JSON) at runtime based on the target domain.

This configuration file defines the "rules of engagement" for that site:

- **Start URLs:** Where to begin crawling.
- **Pagination Rules:** How to find the next page.
- **Extraction Selectors:** The CSS/XPath selectors for Title, Price, etc.
- **Middleware Settings:** Specific proxy pools or concurrency limits for this domain.

This approach aligns with **Configuration Driven Development (CDD)**.13 Adding a new grocery chain does not require writing new Python code; it requires creating a new YAML config. This lowers the barrier to entry, allowing data analysts (who may know CSS selectors but not Python internals) to contribute to scraper coverage.

### **2.4 Data Storage Strategy**

The output of the extraction process must be structured and queryable. While the raw HTML resides in object storage (Data Lake), the extracted data should flow into a Data Warehouse (e.g., Snowflake, BigQuery, or PostgreSQL).1

**Schema Evolution:** Grocery data schemas change. A site might add "Nutri-Score" or "Eco-Score" fields next year. The database schema should use a "semi-structured" approach. Core fields (Price, Name, SKU) are stored in rigid, typed columns for fast indexing. Ancillary or site-specific attributes are stored in a JSONB column (in PostgreSQL) or a Variant column (in Snowflake). This allows the extractor to capture new fields immediately without requiring a database migration.1

**Table 1: Architectural Component Recommendations**

| **Component**      | **Responsibility**                 | **Recommended Technology**  | **Rationale**                                                |
| ------------------ | ---------------------------------- | --------------------------- | ------------------------------------------------------------ |
| **Orchestrator**   | Scheduling & Dependency Management | **Airflow** / **Kestra**    | Handles complex DAGs (e.g., "Don't extract until crawl finishes").12 |
| **Queue**          | Task Buffer & Rate Limiting        | **Redis** / **RabbitMQ**    | Low latency, supports priority queues for urgent pricing updates.9 |
| **Crawler**        | HTTP Interaction & JS Rendering    | **Scrapy** + **Playwright** | Scrapy provides the framework; Playwright handles modern JS-heavy sites.10 |
| **Storage (Raw)**  | Immutable History                  | **S3** / **MinIO**          | Cheap, scalable, allows "time-travel" debugging.1            |
| **Extraction**     | Parsing & Normalization            | **Parsel** + **Pydantic**   | Parsel for speed; Pydantic for strict data validation.5      |
| **Storage (Data)** | Analytics & Querying               | **PostgreSQL** (JSONB)      | Robust relation handling for products + flexibility for attributes.4 |

## **3. Configuration-Driven Extraction Logic**

The heart of the Generic Spider is the configuration DSL (Domain Specific Language). This DSL must be expressive enough to handle complex DOM traversals yet simple enough to maintain.

### **3.1 YAML vs. JSON for Scraper Configuration**

While JSON is the standard for machine-to-machine communication, **YAML** is significantly superior for scraper configuration.16 The primary reasons are:

1. **Comments:** Scrapers are inherently hacky. Engineers need to leave notes explaining *why* a specific, bizarre XPath was used (e.g., # warning: site uses non-breaking spaces in price). JSON does not support comments, making this impossible.18
2. **Readability:** YAML's whitespace-significant syntax is cleaner for deeply nested selector structures.20
3. **Multi-line Strings:** Extracting embedded JavaScript often requires regex patterns that span multiple lines. YAML handles block scalars (|) elegantly, whereas JSON requires escaping every newline, resulting in unreadable strings.19

### **3.2 Designing the Selector Schema**

A robust schema for a grocery site configuration should support a "Waterfall" or "Chain of Responsibility" pattern for selectors. Sites change frequently; relying on a single CSS selector is a recipe for data gaps. The config should allow defining a list of selectors that are tried in order of preference.14

**Example Configuration (YAML):**

YAML

domain: "supermarket-example.com"
version: 2.1
meta:
 maintainer: "data-team-a"
 last_verified: "2025-01-15"

parsing_rules:
 product_name:
  \- type: "xpath"
   value: "//h1[@data-testid='product-title']/text()" # Preferred: Stable ID
  \- type: "css"
   value: "h1.ProductTitle-sc-123::text"       # Fallback: Brittle CSS
  \- type: "meta"
   value: "og:title"                 # Last Resort: Meta tag

 price:
  \- type: "json-ld"
   path: "offers.price"                # Gold standard
  \- type: "css"
   value: ".price-box.current-price::text"
  \- type: "regex"
   pattern: "price:\s*['\"](\d+\.\d+)['\"]"      # Extract from JS source

 availability:
  \- type: "json-ld"
   path: "offers.availability"
  \- type: "css"
   value: ".stock-status::text"
   processors:
    \- "lowercase"
    \- "map_stock_status"               # Custom processor function



This structure allows the extraction engine to be resilient. If the data-testid is removed during a frontend update, the engine silently falls back to the CSS class or Meta tag, logging a warning rather than failing the scrape.21

### **3.3 Implementing the Engine with SelectorLib and Parsel**

To interpret this YAML, the system should leverage **SelectorLib** or build a custom wrapper around **Parsel**.14

**Parsel** is the extraction engine used by Scrapy. It is built on top of lxml and allows for high-performance querying using both CSS and XPath selectors.23 Unlike BeautifulSoup, which constructs a heavy Python object tree for the entire DOM, Parsel uses lxml's C-based tree, making it significantly faster and more memory-efficient for large-scale processing.22

The GenericSpider reads the YAML, compiles the selectors, and applies them to the HTML.

- **SelectorLib** provides a ready-made framework for this, allowing you to define output structures directly in YAML.24
- **Custom Formatters:** The configuration allows specifying "processors" (like lowercase, strip, clean_currency). These map to Python functions that clean the data immediately after extraction, ensuring that the Pydantic models receive clean inputs.14

## **4. Hierarchical Parsing: The "Pyramid of Reliability"**

For grocery data, not all data sources within a page are created equal. A visual price displayed in a div is far more likely to change (or be A/B tested) than the structured data embedded for Google's crawlers. The extraction logic must prioritize sources based on their stability.

### **4.1 Tier 1: Structured Metadata (JSON-LD & Schema.org)**

The "Gold Standard" for extraction is **JSON-LD** (JavaScript Object Notation for Linked Data). Most major grocery chains (Walmart, Tesco, Kroger, Carrefour) embed a script type="application/ld+json" tag in their product pages to improve SEO.25

This data strictly follows the **Schema.org** vocabulary. A Product object contains:

- name: The official product name.
- sku / gtin13: Global identifiers (critical for entity resolution).
- offers: An object containing price, priceCurrency, and availability.

Implementation Strategy:

The extractor should always attempt to locate and parse this JSON block first. Because it is a structured object, it is immune to DOM layout changes (e.g., moving the price from left to right).

1. Use an XPath to select //script[@type='application/ld+json']/text().
2. Parse the text using json.loads().
3. Traverse the JSON to find the @type": "Product" node (sometimes it is nested in a @graph or a list).27
4. If found, extract data and skip DOM parsing.

**Reliability Note:** JSON-LD availability URLs (e.g., http://schema.org/InStock) are standardized, removing the need to parse vague text like "Hurry, only 2 left!".28

### **4.2 Tier 2: Hidden State Injection (Hydration Data)**

Modern Single Page Applications (SPAs) built with React, Next.js, or Vue often "hydrate" the client-side application using a hidden JSON blob embedded in the HTML. This is typically found in:

- window.__NEXT_DATA__
- window.__PRELOADED_STATE__
- var productData = {...}

This data is often richer than the visible HTML, containing internal IDs, exact stock counts (integer values instead of "In Stock"), and warehouse locations.

Extraction Pattern: Use Regex to capture the JSON string: re.search(r'window\.__INITIAL_STATE__\s*=\s*({.*?});', html). Then parse with json.loads(). This is often more reliable than visual selectors because this data structure is coupled to the backend API schema, which changes less frequently than the frontend design.27

### **4.3 Tier 3: Semantic HTML Attributes**

If JSON blobs are missing, prioritize semantic HTML attributes over CSS classes.

- **OpenGraph:** <meta property="og:price:amount" content="2.99" />
- **Data Attributes:** Elements often have data- attributes for analytics tracking (e.g., <div data-price="2.99" data-id="12345">). These are stable interfaces for the site's own JavaScript and are safer scrape targets.21

### **4.4 Tier 4: Visual DOM Selectors (The Fallback)**

Only when the above methods fail should the system resort to traversing the visual DOM (e.g., div.product-price > span). When using this tier, prefer **XPath** over CSS. XPath allows for content-based addressing, such as "Find the span that contains the text '$' and is a sibling of the text 'Price'" (//span[contains(text(), '$')]/preceding-sibling::label[text()='Price']). This is more robust than relying on a class name like .red-text-bold which is purely cosmetic.31

## **5. Semantic Normalization: From Strings to Facts**

Extracting "£1.50" and "300g" is the easy part. The challenge in grocery data is **normalization**. Machine learning models and price comparison engines cannot consume raw strings. They require typed, standardized units.

### **5.1 Price Normalization**

Prices extracted from the web are messy: $2,999.00, 2.50 €, 99¢, USD 5.

The price-parser library is the industry standard for robustly converting these strings into Decimal objects and ISO-4217 currency codes.5

**Normalization Logic:**

- **Decimal Handling:** Automatically detects whether a comma is a thousands separator or a decimal point (e.g., 1.000,00 vs 1,000.00) based on the currency context.
- **Currency Cleaning:** Maps symbols ($, £, €) to codes (USD, GBP, EUR).
- **Zero-Price Validation:** A price of 0.00 usually indicates a scraping error (or a "Call for Price" item) and should be flagged or nulled, rather than recorded as free.33

### **5.2 Unit of Measure (UOM) Normalization**

This is the single most difficult aspect of grocery data. Products are listed in a chaotic array of units:

- *Volume:* fl oz, ml, liters, gallons, pints.
- *Weight:* g, kg, oz, lb, lbs.
- *Count:* 12 pack, 3x200ml, 100 count.

To enable comparison (e.g., "Which milk is cheaper per liter?"), all products must be normalized to a standard **Base Unit** (e.g., Milliliters for volume, Grams for weight).

**The Toolchain: Quantulum3 + Pint**

1. **Entity Extraction (Quantulum3):** This library uses NLP and heuristics to extract measurements from unstructured text. It can disambiguate context. For example, in the string "10 lbs dumbbells", "lbs" is weight. In "Costs 10 pounds", "pounds" is currency. Quantulum3 identifies the quantity (10) and the unit (lbs).6
2. **Unit Conversion (Pint):** Once the unit is identified, **Pint** provides a robust physical quantities registry. It handles the math of conversion.

- ureg("1 lb").to("grams") -> 453.592 grams.
- It prevents invalid conversions (e.g., trying to convert "meters" to "kilograms").7

**Normalization Pipeline Steps:**

1. **Parse Title:** Extract quantities from the product title (e.g., "Heinz Ketchup 20oz").
2. **Standardize String:** Map variations (ltr, l, liter) to Pint-compatible canonical names.
3. **Detect Multipacks:** Use regex patterns (e.g., (\d+)\s*x\s*(\d+)\s*([a-z]+)) to detect "6 x 330ml". The pipeline must calculate the *total volume* (1980ml) for the unit price calculation.36
4. **Convert:** Transform the value to the Base Unit (g/ml).
5. **Calculate Standardized Unit Price:** Price / Normalized_Quantity. This calculated value is often more accurate than the "Unit Price" displayed on the website, which may be inconsistent or missing.38

### **5.3 Stock Status Normalization**

Retailers use varied language for availability: "In Stock", "Low Stock", "Only 2 Left", "Sold Out", "Unavailable", "In Store Only".

These must be mapped to a strict Enum in the database: IN_STOCK, OUT_OF_STOCK, DISCONTINUED, PRE_ORDER.

**Logic:**

- If Schema.org data exists, map the URL http://schema.org/InStock -> IN_STOCK.
- If parsing HTML text, use a prioritized keyword match. "Sold Out" takes precedence over "Low Stock".
- **Visual Absence:** On many sites, "Out of Stock" is indicated by the *absence* of an "Add to Cart" button. The scraper must be configured to check for the *existence* of positive indicators (buy buttons) and default to OUT_OF_STOCK if they are missing.40

## **6. Data Contracts and Validation Pipelines**

In a system processing millions of items, data corruption is inevitable. A selector breaks, and suddenly every "Price" becomes the "Review Count" (e.g., price = 4.5). Without strict validation, this bad data pollutes the database and ruins analytics.

### **6.1 Strict Schemas with Pydantic**

**Pydantic** is the essential tool for defining data contracts in Python.15 It enforces type safety at runtime.

**Example Pydantic Model for Grocery:**

Python

from pydantic import BaseModel, Field, HttpUrl, validator, PositiveFloat
from enum import Enum
from typing import Optional

class StockStatus(str, Enum):
  IN_STOCK = "IN_STOCK"
  OUT_OF_STOCK = "OUT_OF_STOCK"
  UNKNOWN = "UNKNOWN"

class GroceryProduct(BaseModel):
  url: HttpUrl
  name: str = Field(..., min_length=1)
  brand: Optional[str]
  price: PositiveFloat # Automatically rejects negative prices
  currency: str = Field(default="USD", min_length=3, max_length=3)
  stock_status: StockStatus
  normalized_quantity_g: Optional[float]
  
  @validator("stock_status", pre=True)
  def normalize_stock(cls, v):
    if isinstance(v, str):
      v_lower = v.lower()
      if "out" in v_lower or "sold" in v_lower:
        return StockStatus.OUT_OF_STOCK
      if "in stock" in v_lower or "add to cart" in v_lower:
        return StockStatus.IN_STOCK
    return StockStatus.UNKNOWN



Validation Strategy:

When the extraction logic runs, it attempts to instantiate this GroceryProduct model.

- **Strict Mode:** If the price is a string "Call for details", Pydantic raises a ValidationError because it expects a float.
- **Error Handling:** The scraper catches this error, logs it, and discards the item (or sends it to a "Dead Letter" table for inspection). This ensures that **no invalid data ever enters the production database**.42

### **6.2 Monitoring Scraper Health with Spidermon**

Validation catches bad items, but it doesn't alert engineers that a spider is broken. **Spidermon** is a Scrapy extension that monitors the *statistical* health of a crawl.44

**Key Monitors to Configure:**

1. **Item Validation Ratio:** If >5% of items fail Pydantic validation, trigger a high-priority alert (Slack/PagerDuty). This usually means a selector has changed.45
2. **Field Coverage:** If the brand field is null for 90% of items (where it used to be 10%), alert the team. The selector might be pointing to an empty div.46
3. **Throughput Drops:** If the spider extracts 500 items/minute historically but drops to 50 items/minute, the site may be rate-limiting or blocking requests.46

## **7. Entity Resolution: The "Same Product" Problem**

Aggregating data implies merging it. You have 100 prices for "Heinz Ketchup", but they are named differently on every site.

- Site A: "Heinz Tomato Ketchup 20oz"
- Site B: "Heinz Ketchup Squeeze Bottle - 20 oz"
- Site C: "Tomato Ketchup, Heinz Brand"

### **7.1 Deduplication Strategies**

1. Deterministic Matching (GTIN/UPC):

The most reliable method is matching Global Trade Item Numbers (GTIN, UPC, EAN). These are unique identifiers. The extractor must aggressively hunt for these in JSON-LD gtin13 fields or in the HTML source code. If two items have the same GTIN, they are the same item, period.47

2. Probabilistic Matching (Dedupe & Fuzzy Matching):

When GTINs are missing (which is common for fresh produce or store brands), we must use probabilistic matching.

- **Normalization:** First, normalize all strings. Lowercase, remove punctuation, expand abbreviations (oz -> ounce).
- **Blocking:** Group items by "Brand" to reduce the comparison space (don't compare Heinz Ketchup to Colgate Toothpaste).48
- **Active Learning (Dedupe Library):** The dedupe Python library allows you to train a model. You verify a few pairs ("Are these the same? Yes/No"), and it learns the weights. For example, it might learn that matching "20oz" and "20 oz" is highly important, while matching "Bottle" vs "Squeeze" is less important.49
- **Fuzzy String Matching:** Use algorithms like **Levenshtein Distance** or **Jaro-Winkler** (via thefuzz library) to calculate similarity scores. If Title Similarity > 90% AND Brand matches AND Normalized Weight matches, treat as a match.51

## **8. Development Workflow and Testing**

How do you safely update the code for *Walmart* without breaking *Target*?

### **8.1 Snapshot Testing (The "Time Travel" Test)**

Standard unit tests are insufficient because they don't test against real HTML. Network tests are flaky. The solution is Snapshot Testing.

Using libraries like pytest-recording or vcrpy:

1. **Record:** The first time a test runs, it fetches the real HTML from the website and saves it as a local file (fixture).
2. **Replay:** Future tests run against this local file.
3. **Verify:** The test asserts that the extracted data (Price, Name) matches the expected output.53

When a developer modifies the GenericSpider logic, they run the full regression suite. If their change causes the *Walmart* snapshot to parse incorrectly, the test fails immediately. This allows for fearless refactoring of the core extraction engine.55

### **8.2 Containerization and CI/CD**

The entire scraper stack should be containerized using **Docker**.56

- **Base Image:** A lightweight Python image containing Scrapy, Parsel, and Playwright dependencies.
- **Deployment:** When code is pushed to Git, a CI/CD pipeline (GitHub Actions/Jenkins) runs the Snapshot Tests.
- **Registry:** Successful builds push the image to a container registry (ECR/GCR).
- **Orchestration:** The Orchestrator (Airflow) pulls the latest "stable" image to run jobs. This ensures that all worker nodes are always running the exact same version of the extraction logic.56

## **9. Conclusion**

Building a system to extract grocery data from hundreds of chains is not a scripting task; it is a systems engineering challenge. The complexity lies not in the code itself, but in the management of variability.

By adopting an architecture that **decouples crawling from extraction**, the system gains resilience and the ability to repair historical data. By utilizing a **configuration-driven approach** (YAML DSL), the maintenance barrier is lowered, enabling rapid scaling of site coverage. By implementing a **hierarchical parsing strategy** that prioritizes structured metadata (JSON-LD), the system creates a buffer against frontend volatility. Finally, by enforcing **semantic normalization** through Pydantic and unit conversion libraries, the raw noise of the web is transformed into a clean, typed, and analytical-ready dataset.

This architecture shifts the focus from "keeping the scrapers running" to "improving the quality of the data," which is the ultimate goal of any data intelligence operation.

### **Key Data Comparisons**

**Table 2: Comparison of Parsing Libraries for High-Scale Extraction**

| **Feature**          | **Beautiful Soup**      | **Parsel (Scrapy)**         | **lxml**            | **Recommendation** |
| -------------------- | ----------------------- | --------------------------- | ------------------- | ------------------ |
| **Speed**            | Slow (Python-based)     | Fast (C-based lxml backend) | Very Fast           | **Parsel**         |
| **Selector Support** | CSS (limited XPath)     | CSS & XPath (Unified)       | XPath (limited CSS) | **Parsel**         |
| **Memory Usage**     | High (builds full tree) | Moderate                    | Low                 | **Parsel**         |
| **Tolerance**        | High (handles bad HTML) | High                        | Low (strict XML)    | **Parsel**         |
| **Integration**      | Standalone              | Native to Scrapy            | Standalone          | **Parsel**         |

**Table 3: Hierarchy of Selector Reliability**

| **Tier** | **Source**               | **Description**                               | **Stability**   |
| -------- | ------------------------ | --------------------------------------------- | --------------- |
| **1**    | **JSON-LD / Schema.org** | Structured data scripts (application/ld+json) | **Very High**   |
| **2**    | **Hydration State**      | JavaScript variables (window.__NEXT_DATA__)   | **High**        |
| **3**    | **Meta Tags**            | OpenGraph (og:price), Microdata               | **High**        |
| **4**    | **Data Attributes**      | HTML attributes (data-testid="price")         | **Medium**      |
| **5**    | **CSS Classes**          | Visual styling (div.red-bold-text)            | **Low (Avoid)** |
| **6**    | **XPath Text**           | Text position (//text()[contains(., '$')])    | **Low**         |

### **Citations**

1

#### **Works cited**

1. Large-Scale Web Scraping: Challenges, Architecture & Smarter Alternatives - PromptCloud, accessed on January 15, 2026, https://www.promptcloud.com/blog/large-scale-web-scraping-extraction-challenges-that-you-should-know/
2. Best Practices for Scaling Your Web Scraping Projects in 2025 | Crawlbase, accessed on January 15, 2026, https://crawlbase.com/blog/best-practices-for-scaling-your-web-scraping-projects/
3. Data Extraction from Dynamic Web Sites: Combining Crawling and Extraction - Stanford InfoLab, accessed on January 15, 2026, http://infolab.stanford.edu/~rys/papers/crawl.pdf
4. How Do You Clean Large-Scale Scraped Data? : r/webscraping - Reddit, accessed on January 15, 2026, https://www.reddit.com/r/webscraping/comments/1nkxx1r/how_do_you_clean_largescale_scraped_data/
5. price-parser-reworkd - PyPI, accessed on January 15, 2026, https://pypi.org/project/price-parser-reworkd/
6. nielstron/quantulum3: Library for unit extraction - fork of quantulum for python3 - GitHub, accessed on January 15, 2026, https://github.com/nielstron/quantulum3
7. makes units easy — pint 0.10.1 documentation - Read the Docs, accessed on January 15, 2026, https://pint.readthedocs.io/en/0.10.1/
8. Large-Scale Web Scraping: Your 2025 Guide to Building, Running, and Maintaining Powerful Data Extractors - Hir Infotech, accessed on January 15, 2026, https://hirinfotech.com/large-scale-web-scraping-your-2025-guide-to-building-running-and-maintaining-powerful-data-extractors/
9. Infrastructure for hosting a web scraper that scrapes huge quantities of data? (Interview Q) : r/microservices - Reddit, accessed on January 15, 2026, https://www.reddit.com/r/microservices/comments/lncn3r/infrastructure_for_hosting_a_web_scraper_that/
10. The Ultimate Guide to Scalable Web Scraping in 2025: Tools, Proxies, and Automation Workflows - DEV Community, accessed on January 15, 2026, https://dev.to/wisdomudo/the-ultimate-guide-to-scalable-web-scraping-in-2025-tools-proxies-and-automation-workflows-4j6l
11. Design a Web Crawler | Hello Interview System Design in a Hurry, accessed on January 15, 2026, https://www.hellointerview.com/learn/system-design/problem-breakdowns/web-crawler
12. Kestra, Open Source Declarative Orchestration Platform, accessed on January 15, 2026, https://kestra.io/
13. Configuration Driven Development - Stuart Wheaton, accessed on January 15, 2026, https://stuartwheaton.com/blog/2021-10-13-config-driven-development/
14. The YAML Structure - SelectorLib, accessed on January 15, 2026, https://selectorlib.com/yaml.html
15. Models - Pydantic Validation, accessed on January 15, 2026, https://docs.pydantic.dev/latest/concepts/models/
16. JSON vs YAML: What's the Difference, and Which One Is Right for Your Enterprise?, accessed on January 15, 2026, https://www.snaplogic.com/blog/json-vs-yaml-whats-the-difference-and-which-one-is-right-for-your-enterprise
17. Comparing JSON and YAML: A Guide for Developers | by Md Faizan Alam - Medium, accessed on January 15, 2026, https://medium.com/@faizan711/comparing-json-and-yaml-a-guide-for-developers-9c4d91ca5e7a
18. What is the difference between YAML and JSON? - Stack Overflow, accessed on January 15, 2026, https://stackoverflow.com/questions/1726802/what-is-the-difference-between-yaml-and-json
19. Why did YAML become the preferred configuration format instead of JSON? - Reddit, accessed on January 15, 2026, https://www.reddit.com/r/learnprogramming/comments/1m9yyba/why_did_yaml_become_the_preferred_configuration/
20. Building Custom YAML-DSL in Python - DEV Community, accessed on January 15, 2026, https://dev.to/keploy/building-custom-yaml-dsl-in-python-3a6o
21. Mastering CSS Selectors in BeautifulSoup for Efficient Web Scraping - ScrapingAnt, accessed on January 15, 2026, https://scrapingant.com/blog/beautifulsoup-css-selectors
22. Web Scraping With Parsel in Python: A Complete 2026 Guide - Bright Data, accessed on January 15, 2026, https://brightdata.com/blog/web-data/web-scraping-with-parsel
23. Ultimate Web Scraping Guide with Parsel in Python - Crawlbase, accessed on January 15, 2026, https://crawlbase.com/blog/ultimate-web-scraping-guide-with-parsel-in-python/
24. SelectorLib - SelectorLib, accessed on January 15, 2026, https://selectorlib.com/
25. Getting started with schema.org using Microdata, accessed on January 15, 2026, https://schema.org/docs/gs.html
26. How to scrape dynamic websites : r/webscraping - Reddit, accessed on January 15, 2026, https://www.reddit.com/r/webscraping/comments/1knw2c0/how_to_scrape_dynamic_websites/
27. scraping json with scrapy item loaders - python - Stack Overflow, accessed on January 15, 2026, https://stackoverflow.com/questions/79065118/scraping-json-with-scrapy-item-loaders
28. ItemAvailability - Schema.org Enumeration Type, accessed on January 15, 2026, https://schema.org/ItemAvailability
29. Updating Schema.org availability on my website - Stack Overflow, accessed on January 15, 2026, https://stackoverflow.com/questions/32765474/updating-schema-org-availability-on-my-website
30. python web scraping of a dynamically loading page - Stack Overflow, accessed on January 15, 2026, https://stackoverflow.com/questions/22862540/python-web-scraping-of-a-dynamically-loading-page
31. Scrapy Tutorial — Scrapy 2.14.1 documentation, accessed on January 15, 2026, https://docs.scrapy.org/en/latest/intro/tutorial.html
32. Usage — Parsel 1.10.0 documentation, accessed on January 15, 2026, https://parsel.readthedocs.io/en/latest/usage.html
33. Unveiling the Best Free Tool for Price Scraping - Zyte, accessed on January 15, 2026, https://www.zyte.com/blog/price-scraping-best-free-tool-to-scrape-prices/
34. CQE: A Comprehensive Quantity Extractor - ACL Anthology, accessed on January 15, 2026, https://aclanthology.org/2023.emnlp-main.793.pdf
35. Tutorial — pint 0.1.dev50+g84762624b documentation - Read the Docs, accessed on January 15, 2026, https://pint.readthedocs.io/en/stable/getting/tutorial.html
36. Regex to parse Product Size (Count, Pack size) from string - Stack Overflow, accessed on January 15, 2026, https://stackoverflow.com/questions/59866057/regex-to-parse-product-size-count-pack-size-from-string
37. Regex Parse from String - KNIME Forum, accessed on January 15, 2026, https://forum.knime.com/t/regex-parse-from-string/75288
38. Comparing food prices - Per unit pricing, accessed on January 15, 2026, https://ised-isde.canada.ca/site/office-consumer-affairs/en/modern-marketplace/comparing-food-prices-unit-pricing
39. Unit pricing | Real Life, Good Food, accessed on January 15, 2026, https://reallifegoodfood.umn.edu/shop-smart/unit-pricing
40. 10 Tips to Deal with Out-of-Stock Product Pages - Easyship, accessed on January 15, 2026, https://www.easyship.com/blog/10-tips-to-deal-with-out-of-stock-product-pages
41. How to Optimize Your E-Commerce Website's Out-of-Stock Product Pages | Floship, accessed on January 15, 2026, https://www.floship.com/blog/optimize-ecommerce-websites-out-of-stock-pages/
42. JSON - Pydantic Validation, accessed on January 15, 2026, https://docs.pydantic.dev/latest/concepts/json/
43. Scrape but Validate: Data scraping with Pydantic Validation - DEV Community, accessed on January 15, 2026, https://dev.to/ajitkumar/scrape-but-validate-data-scraping-with-pydantic-validation-453k
44. Scrapy monitoring: managing your Scrapy spider - Apify Blog, accessed on January 15, 2026, https://blog.apify.com/scrapy-monitoring-spidermon/
45. Item Validation - Spidermon documentation - Read the Docs, accessed on January 15, 2026, https://spidermon.readthedocs.io/en/latest/item-validation.html
46. The Complete Guide To Scrapy Spidermon, Start Monitoring in 60 Seconds! | ScrapeOps, accessed on January 15, 2026, https://scrapeops.io/python-scrapy-playbook/extensions/scrapy-spidermon-guide/
47. Entity Resolution Challenges : r/Python - Reddit, accessed on January 15, 2026, https://www.reddit.com/r/Python/comments/15jgiqn/entity_resolution_challenges/
48. dedupe - PyPI, accessed on January 15, 2026, https://pypi.org/project/dedupe/
49. dedupeio/dedupe: :id: A python library for accurate and scalable fuzzy matching, record deduplication and entity-resolution. - GitHub, accessed on January 15, 2026, https://github.com/dedupeio/dedupe
50. Basics of Entity Resolution with Python and Dedupe | by District Data Labs - Medium, accessed on January 15, 2026, https://medium.com/district-data-labs/basics-of-entity-resolution-with-python-and-dedupe-bc87440b64d4
51. Fuzzy String Matching in Python Tutorial - DataCamp, accessed on January 15, 2026, https://www.datacamp.com/tutorial/fuzzy-string-python
52. Fuzzy Data Matching Guide for Data-Driven Decision-Making - WinPure, accessed on January 15, 2026, https://winpure.com/fuzzy-matching-guide/
53. Introducing pytest-r-snapshot: Verifying Python code against R outputs at scale - Nan Xiao, accessed on January 15, 2026, https://nanx.me/blog/post/pytest-r-snapshot/
54. Snapshot testing with Syrupy - Simon Willison: TIL, accessed on January 15, 2026, https://til.simonwillison.net/pytest/syrupy
55. Building Reliable Python Scrapers with Pytest | by Laércio de Sant' Anna Filho | Medium, accessed on January 15, 2026, https://laerciosantanna.medium.com/mastering-web-scraping-a-guide-to-crafting-reliable-python-scrapers-with-pytest-1d45db7af92b
56. How we manage 100s of scrapy spiders - Stackadoc, accessed on January 15, 2026, https://www.stackadoc.com/blog/how-we-manage-100s-of-scrapy-spiders
57. The ultimate guide to building scalable, reliable web scraping, monitoring, and automation apps - DEV Community, accessed on January 15, 2026, https://dev.to/kamilms21/the-ultimate-guide-to-building-scalable-reliable-web-scraping-monitoring-and-automation-apps-6cd
58. How to Ensure Web Scrapped Data Quality - Scrapfly, accessed on January 15, 2026, https://scrapfly.io/blog/posts/how-to-ensure-web-scrapped-data-quality
59. price-parser - PyPI, accessed on January 15, 2026, https://pypi.org/project/price-parser/