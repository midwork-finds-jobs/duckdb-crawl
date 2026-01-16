# Next steps
We have rust library which parses html including the javascript in the script tags. It's in ~/Projects/html_parser/ and you can change it as you see fit.

Your goal is to be able to provide this functionality to the user of duckdb crawler extension:

```sql
CRAWL (SELECT 'https://www.matsmart.fi/sitemap.xml')
INTO matsmart_pages
EXTRACT (
    jsonld.Product.name,
    COALESCE(jsonld.Product.gtin13, microdata.Product.gtin) as gtin,
    js.siteConfig.price,
    unit_price DECIMAL FROM css 'div.container .unit-price::text' | parse_price
);
WHERE url LIKE 'https://www.matsmart.fi/tuote/%'
WITH (user_agent 'MyBot/1.0');
```

One way to do this is to follow the FFI path described below. One way could be to move the http requests from this repository into rust side and use async tokio based http requests and write into the duckdb database from the rust side.

DuckDB allows building extensions both on C++ and Rust. But Rust side has this limitation:
* SQL parser extension requires modifying DuckDB core (C++)
* Complex filter pushdown (WHERE clause interception) is not exposed in the Rust bindings or C API.

Explore first ideal architecture of how everything should work together.

## Rust FFI to DuckDB C++ API - Recipe

1. C++ Side (src/your_wrapper.cpp)

  #include <duckdb.hpp>
  #include <cstring>

  extern "C" {

  // Opaque struct holds C++ objects
  struct MyProcessor {
      std::unique_ptr<duckdb::DuckDB> database;
      std::unique_ptr<duckdb::Connection> connection;
  };

  // Create - returns opaque pointer
  void* my_create_connection(const char* db_path) {
      try {
          auto proc = new MyProcessor();
          proc->database = std::make_unique<duckdb::DuckDB>(db_path);
          proc->connection = std::make_unique<duckdb::Connection>(*proc->database);
          return static_cast<void*>(proc);
      } catch (...) {
          return nullptr;
      }
  }

  // Execute - takes opaque pointer, returns error code
  int my_execute_sql(void* conn, const char* sql, char** error_msg) {
      auto* proc = static_cast<MyProcessor*>(conn);
      try {
          auto result = proc->connection->Query(sql);
          if (result->HasError()) {
              *error_msg = strdup(result->GetError().c_str());
              return 1;
          }
          return 0;
      } catch (const std::exception& e) {
          *error_msg = strdup(e.what());
          return 1;
      }
  }

  // Destroy - cleans up
  void my_destroy_connection(void* conn) {
      delete static_cast<MyProcessor*>(conn);
  }

  void my_free_string(char* s) { free(s); }

  } // extern "C"

  2. Rust Side (src/my_processor.rs)

  use std::ffi::{CStr, CString};
  use std::os::raw::{c_char, c_void};
  use anyhow::Result;

  // FFI declarations
  extern "C" {
      fn my_create_connection(db_path: *const c_char) -> *mut c_void;
      fn my_execute_sql(conn: *mut c_void, sql: *const c_char, error_msg: *mut *mut c_char) -> i32;
      fn my_destroy_connection(conn: *mut c_void);
      fn my_free_string(s: *mut c_char);
  }

  // Safe wrapper struct
  pub struct MyProcessor {
      handle: *mut c_void,
  }

  unsafe impl Send for MyProcessor {}
  unsafe impl Sync for MyProcessor {}

  impl MyProcessor {
      pub fn new(db_path: &str) -> Result<Self> {
          let path_c = CString::new(db_path)?;
          let handle = unsafe { my_create_connection(path_c.as_ptr()) };
          if handle.is_null() {
              return Err(anyhow::anyhow!("Failed to create connection"));
          }
          Ok(Self { handle })
      }

      pub fn execute_sql(&self, sql: &str) -> Result<()> {
          let sql_c = CString::new(sql)?;
          let mut error_msg: *mut c_char = std::ptr::null_mut();

          let code = unsafe { my_execute_sql(self.handle, sql_c.as_ptr(), &mut error_msg) };

          if code != 0 {
              let err = if !error_msg.is_null() {
                  let msg = unsafe { CStr::from_ptr(error_msg).to_string_lossy().into_owned() };
                  unsafe { my_free_string(error_msg) };
                  msg
              } else {
                  "Unknown error".to_string()
              };
              return Err(anyhow::anyhow!(err));
          }
          Ok(())
      }
  }

  impl Drop for MyProcessor {
      fn drop(&mut self) {
          if !self.handle.is_null() {
              unsafe { my_destroy_connection(self.handle) };
          }
      }
  }

  3. Build Configuration (build.rs)

  fn main() {
      cc::Build::new()
          .cpp(true)
          .file("src/your_wrapper.cpp")
          .include("/path/to/duckdb/include")
          .flag("-std=c++17")
          .compile("duckdb_wrapper");

      println!("cargo:rustc-link-lib=duckdb");
  }