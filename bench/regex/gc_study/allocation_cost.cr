# The cost of one heap allocation on this machine (GC-free study): the
# nanoseconds per `GC.malloc` and `GC.malloc_atomic` at the sizes a
# runtime search allocates, with the collector on (collections amortized
# in) and off, the two interleaved three times; the median is printed.
#
#   crystal-alpha build --release bench/regex/gc_study/allocation_cost.cr -o bench/bin/regex/allocation_cost
COUNT = 5_000_000

def time_allocations(size : Int32, atomic : Bool) : Float64
  sink = Pointer(Void).null
  started = Time.instant
  COUNT.times do
    sink = atomic ? GC.malloc_atomic(size) : GC.malloc(size)
  end
  elapsed = (Time.instant - started).total_nanoseconds / COUNT
  # Keeps the last pointer alive so the loop is not removed.
  STDERR.print "" if sink.null?
  elapsed
end

{ {48, false}, {64, false}, {168, false}, {256, true}, {1024, true} }.each do |size, atomic|
  on = [] of Float64
  off = [] of Float64
  3.times do
    on << time_allocations(size, atomic)
    GC.collect
    GC.disable
    off << time_allocations(size, atomic)
    GC.enable
    GC.collect
  end
  kind = atomic ? "malloc_atomic" : "malloc"
  puts "#{kind}(#{size}): #{on.sort[1].round(1)} ns with the collector on, #{off.sort[1].round(1)} ns with it off"
end
