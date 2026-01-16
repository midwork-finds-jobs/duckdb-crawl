Yes. Since your goal is specifically **extraction** (finding data) rather than **execution** (running the code), you generally do not need a full JavaScript engine (like V8 or SpiderMonkey). You need a **static analysis tool** or a dedicated **parser**.

Here are the best lightweight options for Rust and C++ that allow you to construct an AST (Abstract Syntax Tree) to reliably locate variables.

------

### Top Recommendation: Tree-sitter (C++ & Rust)

**Tree-sitter** is arguably your best option for this specific use case. It is a parser generator tool and an incremental parsing library.

- **Why it fits:** It is designed for static analysis, syntax highlighting, and code extraction. It is extremely fast, fault-tolerant (it won't crash on slightly malformed JS), and has native bindings for both **C++** and **Rust**.
- **How to use it:** You don't write manual traversal code. You use **Tree-sitter Queries** (a pattern-matching language similar to CSS selectors but for code) to grab exactly the nodes you want.

**Workflow:**

1. Parse HTML (using `html5ever` in Rust or `Lexbor`/`Gumbo` in C++) to get the text inside `<script>` tags.
2. Pass that text to `tree-sitter-javascript`.
3. Run a query to find variable assignments.

**Example Query (Scheme-like syntax used by Tree-sitter):**

Code snippet

```
(variable_declarator
  name: (identifier) @var_name
  value: (_) @var_value)
```

This instantly extracts the name and value of every variable defined in the script.

### 2. Rust Options

If you prefer a pure Rust ecosystem, these libraries are excellent for parsing JavaScript into an AST.

#### **swc (Speedy Web Compiler)**

This is currently the industry standard for high-performance JavaScript tooling in Rust (used by Next.js, Deno, etc.).

- **Pros:** Incredibly fast. Produces a complete, standards-compliant ECMAScript AST.
- **Cons:** The API is complex because it is designed for transpilation, not just extraction.
- **Usage:** You would use the `swc_ecma_parser` crate to generate the AST, then use the `Visit` trait to traverse the tree and listen for `VarDecl` nodes.

#### **Oxidized (Oxc)**

A newer, extremely high-performance parser written in Rust.

- **Pros:** Often faster than SWC; designed specifically for linter/transformer tasks.
- **Usage:** Similar to SWC, you parse the source into an AST and walk the tree to find your data.

#### **Boa (The Parser)**

Boa is a JS engine written in Rust, but its parser is decoupled.

- **Pros:** Easier API than SWC. If you eventually decide you *do* need to execute a tiny bit of code (e.g., to resolve `var x = 5 + 5`), you can easily upgrade from using just the parser to using the engine.

### 3. C++ Options

Pure parsing libraries in C++ are rarer than in Rust (most C++ projects just embed a full engine), but lightweight embeddable engines are a viable path here.

#### **QuickJS**

While technically an engine, QuickJS is remarkably small (a few megabytes) and has a C API.

- **Strategy:** Instead of parsing it yourself, you can load the script into the QuickJS runtime and then inspect the `global` object to read the variables out.
- **Pros:** Handles complex cases where variables are calculated (e.g., `var config = JSON.parse('{"a":1}')`). A static parser effectively cannot handle calculated variables, but QuickJS can.

#### **Duktape**

Similar to QuickJS, but older and very battle-tested. It is ANSI C, easy to integrate into C++, and has a very small footprint.

------

### Comparison Table

| **Library**     | **Language**   | **Type**      | **Best For**                                       |
| --------------- | -------------- | ------------- | -------------------------------------------------- |
| **Tree-sitter** | **Rust / C++** | Parser (CST)  | **Best Overall.** Robust extraction using queries. |
| **swc**         | Rust           | Parser (AST)  | High-performance, standards-compliant AST.         |
| **Boa**         | Rust           | Engine/Parser | If you might need execution later.                 |
| **QuickJS**     | C / C++        | Tiny Engine   | If you need to resolve calculated values.          |

### Summary Recommendation

1. If you just need to scrape static values (e.g., var x = "123";):

   Use Tree-sitter (available in both C++ and Rust). It is the most lightweight, robust, and easiest to maintain for extraction tasks.

2. If you are using Rust and want a standard AST:

   Use swc.

3. If the variables are calculated (e.g., encoded strings or math):

   You cannot use a parser; you need a runtime. Use QuickJS (C++) or Boa (Rust).

**Would you like a code snippet showing how to use Tree-sitter in Rust to extract a specific variable name?**