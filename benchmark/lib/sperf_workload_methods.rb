# frozen_string_literal: true

require "sperf_workload"

module SperfWorkload
  # Pure Ruby busy-wait methods: rw1 ~ rw1000
  # Each method is defined separately so rb_profile_frame_label
  # returns a distinct name per method.
  1.upto(1000) do |i|
    module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
      def self.rw#{i}(n_usec)
        target = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) + n_usec / 1_000_000.0
        nil while Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) < target
      end
    RUBY
  end

  # C-level busy-wait methods: cw1 ~ cw1000
  # Defined in ext/sperf_workload/sperf_workload.c via rb_define_module_function
end
