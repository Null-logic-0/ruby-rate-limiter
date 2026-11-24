-- Sliding window counter, run atomically inside Redis.
--
-- KEYS[1]  the key's hash: index, current, previous
-- ARGV[1]  limit
-- ARGV[2]  window in seconds
-- ARGV[3]  cost
-- ARGV[4]  now in seconds, or "" for the Redis clock
-- ARGV[5]  reserve (0 if missing)
--
-- Returns { allowed (1/0), estimate, current, previous, index, now }

local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local cost = tonumber(ARGV[3])
local now = tonumber(ARGV[4])
local reserve = tonumber(ARGV[5]) or 0

if now == nil then
  local time = redis.call('TIME')
  now = tonumber(time[1]) + tonumber(time[2]) / 1000000
end

local index = math.floor(now / window)
local stored = redis.call('HMGET', key, 'index', 'current', 'previous')
local stored_index = tonumber(stored[1])
local current = tonumber(stored[2]) or 0
local previous = tonumber(stored[3]) or 0

-- Move to the window containing `now`. If time went back, stay.
if stored_index == nil then
  stored_index = index
elseif index > stored_index then
  if index == stored_index + 1 then
    previous = current
  else
    previous = 0
  end
  current = 0
  stored_index = index
end

local window_start = stored_index * window
local progress = (now - window_start) / window
if progress < 0 then progress = 0 elseif progress > 1 then progress = 1 end

local estimate = previous * (1 - progress) + current
local allowed = 0
if estimate + cost + reserve <= limit + 1e-9 then
  allowed = 1
  current = current + cost
  estimate = estimate + cost
end

redis.call('HSET', key, 'index', stored_index, 'current', current, 'previous', previous)
-- Expire after two windows, when it no longer counts.
redis.call('PEXPIRE', key, math.max(1, math.ceil((window_start + 2 * window - now) * 1000)))

-- Redis turns Lua numbers into integers, so send decimals as strings.
return { allowed, tostring(estimate), current, previous, stored_index, tostring(now) }