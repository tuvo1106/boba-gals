Gem::Specification.new do |spec|
  spec.name    = "deficit_scheduler"
  spec.version = "0.1.0"
  spec.authors = [ "Tu Vo" ]
  spec.summary = "Deficit round robin work scheduling as a pure function"
  spec.description = <<~TEXT
    Fair-queuing work scheduler: deficit round robin over flows, with aging so
    nothing starves, a priority tier for expedited work, backward scheduling for
    deadlines, and a staleness boost for flows whose first output is going off.
    `DeficitScheduler.pick_next(state, now)` is a pure function — no clock
    access, no I/O — so a simulator can run the production scheduler unmodified.
  TEXT
  spec.homepage = "https://github.com/tuvo1106/boba-gals"

  # No `license` field on purpose: the repository carries no LICENSE file, and
  # claiming one in metadata that nothing in the tree backs up would be a false
  # claim on a public repo. Set it — and add the file — if this is ever
  # published (ADR-0033's "revisit when").

  spec.required_ruby_version = ">= 3.2"

  # Deliberately globbed rather than `git ls-files`: the Docker build COPYs this
  # gemspec in before the rest of the source (Dockerfile), so anything that
  # shells out to git or reads a sibling version file would fail at
  # `bundle install` time. A Dir glob just returns [] there, which is fine.
  spec.files = Dir["lib/**/*.rb"] + Dir["README.md"] + Dir["LICENSE*"]
  spec.require_paths = [ "lib" ]

  # **Zero runtime dependencies, on purpose.** This is the boundary: the pure
  # scheduler must not require Rails to load, and a gemspec that declares
  # nothing is a harder guarantee than a spec helper that happens not to load
  # it. Adding a dependency here should feel like the deliberate act it is.

  spec.metadata["rubygems_mfa_required"] = "true"
end
