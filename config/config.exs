import Config

# Not shipped in the package (see the `files` list in mix.exs): this is how
# the suite reproduces the Ash settings AshCache is meant to run under.
config :ash,
  # Generation bumping runs in after_transaction; the read side's hooks have
  # to observe writes in the order they happened. A host that sets this
  # differently gets different results.
  read_action_after_action_hooks_in_order?: true,
  # Policy-filtered reads must return rows, not a static forbidden error,
  # for the actor-scoped cache key tests to exercise anything.
  policies: [no_filter_static_forbidden_reads?: false],
  # Ash requires an explicit answer; this one only reaches the suite's
  # fixture attributes, never anything AshCache itself does.
  default_string_length_count: :codepoints

config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal
