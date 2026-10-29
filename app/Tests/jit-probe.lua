-- Does LuaJIT's trace compiler work in this process? Prints one line and exits non-zero if not.
-- (Hardened runtime without com.apple.security.cs.allow-jit forbids the executable memory the
-- compiler needs; LuaJIT then either dies or silently stays an interpreter.)
local ffi = require("ffi")
local function hot(n) local s = 0 for i = 1, n do s = s + (i % 7) * 3 end return s end
local t0 = os.clock()
local result = hot(2e8)
local elapsed = os.clock() - t0
local status = jit.status()
-- The interpreter does this loop at roughly 1e8 iterations/s on Apple silicon; compiled code is far faster.
local compiled = elapsed < 0.6
print(string.format("jit.status=%s result=%d elapsed=%.3fs %s", tostring(status), result, elapsed, compiled and "COMPILED" or "INTERPRETED"))
-- ffi, as microfish.lua uses it for its clock.
ffi.cdef("typedef struct { long tv_sec; long tv_nsec; } probe_timespec; int clock_gettime(int, probe_timespec*);")
local ts = ffi.new("probe_timespec"); assert(ffi.C.clock_gettime(6, ts) == 0)
-- Standard libraries microfish.lua relies on.
assert(os.getenv and io.open and os.rename and dofile and loadfile, "std libs")
os.exit(compiled and 0 or 1)
