import Config

# Test-suite settings only; AshCache needs none of them from a host app
# (verified by flipping each and running the suite).
config :ash,
  # Ash's recommended value; the suite passes with either.
  read_action_after_action_hooks_in_order?: true,
  # With Ash's default (true), an actorless read of a policy-guarded resource
  # is a Forbidden error, so the "cached rows never leak" tests would never
  # reach the cache. `false` makes them return filtered rows instead, which
  # is the path those tests exist to check.
  policies: [no_filter_static_forbidden_reads?: false],
  # Ash requires an explicit answer; this one only reaches the suite's
  # fixture attributes, never anything AshCache itself does.
  default_string_length_count: :codepoints

config :ash_cache, adapter: AshCache.Store.Adapters.ProcessLocal
