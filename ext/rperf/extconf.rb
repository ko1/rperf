require "mkmf"

have_header("pthread.h") or abort "pthread.h not found"
have_library("pthread") or abort "libpthread not found"

create_makefile("rperf")
