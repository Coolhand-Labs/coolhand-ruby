# Declaring workloads and templates

By default Coolhand works out which workload and template an LLM call belongs to by matching the log against known templates. If your code already knows (a service object, a prompt library, an adapter), declare it instead. A declared log skips matching entirely and is filed under the workload and template you named.

There are two parts:

- `Coolhand.with_context` stamps the LLM calls the gem captures automatically.
- `Coolhand.workload_service.upsert` and `Coolhand.template_service.upsert` create or rename workloads and templates explicitly. They need your **private** API key.

## Declaring on captured calls

```ruby
Coolhand.with_context(
  source: "squishling",
  workload: { key: "Parser#call", name: "Parser#call", description: "Parses incoming tickets" },
  template: { key: "Parser#call/squish:L2", name: "Parser#call · squish L2" }
) do
  client.chat(...) # captured as usual, and sent with the declared identity
end
```

| Field | Accepts | Notes |
|---|---|---|
| `source` | String | Where the declaration came from, e.g. the library that made it. |
| `workload` | Hash: `id`, `key`, `name`, `description` | Needs an `id` or a `key`. Other keys are ignored. |
| `template` | Hash: `id`, `key`, `name` | Needs an `id` or a `key`. Other keys are ignored. |

- `id` refers to an existing record. `key` is a stable string of your choosing; Coolhand finds or creates the record with that key. On a template, `id` wins over `key`.
- `name` and `description` label a record when it is created.
- Keys are at most 255 characters, printable, and cannot start or end with `/` or contain `//`.
- A `workload` or `template` that is not a Hash, or has neither `id` nor `key`, raises `ArgumentError` before your block runs.

### Nesting

Blocks nest. Each field (`source`, `workload`, `template`) is taken from the innermost block that sets it, and fields an inner block leaves out are inherited (with the one exception below):

```ruby
Coolhand.with_context(source: "my-app", workload: { key: "Parser#call" }) do
  Coolhand.with_context(template: { key: "Parser#call/summarize" }) do
    # source: "my-app", workload: Parser#call, template: Parser#call/summarize
  end
end
```

A template belongs to a workload, so an inner block that declares a `workload` without a `template` does not inherit the outer block's template. Declare both together when you change workload.

A `workload` or `template` Hash is replaced as a whole, not merged key by key. An inner `workload: { key: "b" }` inside an outer `workload: { id: "a" }` declares only `b`, rather than a mix of `id` and `key`.

### Threads and background logging

The context is thread-local, like `Coolhand.with_capture`. It is also fiber-local, so it does not carry into threads, fibers, `Enumerator#next` blocks or async tasks you start inside the block; calls made there are captured without a declaration. The identity is read on the thread that made the LLM call, before the log is queued, so it survives `async_logging` (the default).

### Public keys

Declarations made with a public key are capped per client. Over the cap, Coolhand ignores the declaration, ingests the log normally, and returns a warning, which the gem prints unless `config.silent` is on. Declarations from a private key are not capped.

Older Coolhand servers ignore `declared`, so it is safe to use against them.

## Declaring on a class

Wrapping every call site in `with_context` does not suit passive capture. Include `Coolhand::Declarable` and declare the identity once, on the class. Wrapped methods run inside `with_context`, so everything above (nesting, precedence, async) applies unchanged.

```ruby
class ApplicationService
  include Coolhand::Declarable

  coolhand_workload source: "my-app"
  coolhand_declare_all
end

class Parser < ApplicationService
  def call(ticket) = client.chat(...) # workload "Parser#call", template "Parser#call"
end

class Summariser < ApplicationService
  coolhand_workload key: "Summariser" # one workload for every method; templates stay per method

  def call(ticket) = client.chat(...) # workload "Summariser", template "Summariser#call"
end
```

- `coolhand_declare :call, :other` wraps just those methods, whether they are defined before or after the line. `template:` takes a key or a `{ key:, name: }` Hash instead of the default `"ClassName#method"`: `coolhand_declare :call, template: "Parser#call/summarise"`.
- `coolhand_declare_all` wraps every public instance method defined after it, in the class and its subclasses, so put it at the top of the class body. Private and protected methods are left alone, however they are made private (`private def`, `private :name`, or a `private` section), as are attribute readers and writers and object-protocol methods such as `to_s`, `==` and `method_missing`. A method you name in `coolhand_declare` is wrapped regardless.
- The key uses the **runtime** class, so a method inherited from `ApplicationService` declares as `Parser#call` when called on a `Parser`. Anonymous classes are not declared.
- `coolhand_workload(key:, name:, description:, source:)` sets class-level defaults and is inherited by subclasses, field by field, with the nearest class winning. Without a `key`, each method gets its own workload, `ClassName#method`.
- Services that call each other nest: the innermost wrapped method wins, and it brings its own template (see [Nesting](#nesting)).
- It only works where the LLM call runs on the same thread and fiber as the wrapped method.

## Rails auto-declare

For Rails apps, Coolhand can declare jobs and controller actions without touching their classes. It is off by default, because every distinct job and action becomes a workload.

```ruby
Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_API_KEY")
  config.auto_declare = [:active_job, :controller]
end
```

| Target | Wraps | Declares |
|---|---|---|
| `:active_job` | `around_perform` on `ActiveJob::Base` | `SummariseJob#perform`, source `rails` |
| `:controller` | `around_action` on `ActionController::Base` and `::API` | `UsersController#show`, source `rails` |

Coolhand must be loaded after Rails (the default with `Bundler.require` in a Rails app), otherwise the hooks are never registered. They are installed after your initializers have run, so `Coolhand.configure` can come before or after anything else. Anything declared inside the job or action (a `Declarable` service, a `with_context` block) takes precedence over the job or action declaration. With a public API key the per-client declaration cap applies (see [Public keys](#public-keys)), so enable only the targets you want as workloads.

## Creating and renaming explicitly

```ruby
Coolhand.configure { |config| config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY") }

workload = Coolhand.workload_service.upsert(
  key: "Parser#call", name: "Parser", description: "Parses incoming tickets", source: "my-app"
)

Coolhand.template_service.upsert(
  key: "Parser#call/summarize",
  workload: { key: "Parser#call" }, # or { id: workload[:id] }
  name: "Parser · summarize",
  source: "my-app"
)
```

- Both are `PUT .../by_key/<key>`: they create the record if the key is new and update it otherwise. The server answers `201` on create and `200` on update; both return the record as a Hash.
- The key never changes. Calling `upsert` with the same key and a new `name` renames the record.
- A template needs a `workload` (`{ id: }`, or `{ key: }` which is found or created) when it is new. An existing template keeps its workload.
- A key may contain `/`, `#`, `:` and other characters; the gem escapes it for the URL.

## Errors

`upsert` raises, unlike the logging writes. A non-2xx response raises `Coolhand::HttpError` whose `status` is the HTTP code (`401` for a missing or public key, `422` for an invalid key or unknown workload, `504` if the server timed out). A blank key, or one made of `.` / `..` path segments, and transport failures raise `Coolhand::Error`; a `workload` that is not a Hash raises `ArgumentError`.

`config.debug_mode` does not suppress `upsert`: it changes server state, so it is always sent.
