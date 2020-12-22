local tostring = tostring
local string_format = string.format
local math_floor = math.floor
local ngx_now = ngx.now
local setmetatable = setmetatable

local _M = {}
local mt = { __index = _M }

local DEFAULT_WINDOW_SIZE = 60 * 1000 -- milliseconds

-- uniquely identifies the window associated with given time
local function get_id(self, time)
  return tostring(math_floor(time / self.window_size))
end

-- counter key is made of the identifier of current sliding window instance,
-- and identifier of the current window. This makes sure it is unique
-- per given sliding window instance in the given window.
local function get_counter_key(self, sample, time)
  local id = get_id(self, time)
  return string_format("%s.%s.counter", sample, id)
end

local function get_last_rate(self, sample, now_ms)
  local a_window_ago_from_now = now_ms - self.window_size
  local last_counter_key = get_counter_key(self, sample, a_window_ago_from_now)

  -- NOTE(elvinefendi): returning 0 as a default value here means
  -- we will allow spike in the first window or in the window that
  -- has no immediate previous window with samples.
  -- What if we default to self.limit here?
  local last_count = self.store:get(last_counter_key) or 0

  return last_count / self.window_size
end

function _M.new(store, limit, window_size)
  if not store then
    return nil, "'store' parameter is missing"
  end
  if not store.incr then
    return nil, "'store' has to implement 'incr' function"
  end
  if not store.get then
    return nil, "'store' has to implement 'get' function"
  end

  return setmetatable({
    store = store,
    limit = limit,
    window_size = window_size or DEFAULT_WINDOW_SIZE, -- milliseconds
  }, mt), nil
end

function _M.add_sample(self, sample)
  local now_ms = ngx_now() * 1000

  local counter_key = get_counter_key(self, sample, now_ms)

  local expiry = self.window_size * 2 / 1000 --seconds

  local _, err = self.store:incr(counter_key, 1, expiry)
  if err then
    return err
  end

  return nil
end

function _M.is_limit_exceeding(self, sample)
  local now_ms = ngx_now() * 1000

  local counter_key = get_counter_key(self, sample, now_ms)

  local count, err = self.store:get(counter_key)
  if err then
    return nil, nil, err
  end
  if not count then
    count = 0
  end

  local last_rate = get_last_rate(self, sample, now_ms)
  local elapsed_time = now_ms % self.window_size
  local estimated_total_count =
    last_rate * (self.window_size - elapsed_time) + count

  local limit_exceeding = estimated_total_count >= self.limit
  local delay_ms = nil

  if limit_exceeding then
    if last_rate == 0 then
      -- When the last rate is 0, and limit is exceeding that means the limit
      -- in the current window is precisely met (without estimation,
      -- refer to the above formula). Which means we have to wait until the
      -- next window to allow more samples.
      delay_ms = self.window_size - elapsed_time
    else
      -- The following formula is obtained by solving the following equation
      -- for `delay_ms`:
      -- last_rate * (self.window_size - (elapsed_time + delay_ms)) + count =
      --   self.limit - 1
      -- This equation is comparable to total count estimation for the current
      -- window formula above. Basically the idea is, how long more (delay_ms)
      -- should we wait before estimated total count is below the limit again.
      delay_ms =
        self.window_size - (self.limit - count) / last_rate - elapsed_time
    end

    -- Unless weird time drifts happen or counter is borked,
    -- this should never be true.
    if delay_ms > self.window_size or delay_ms < 0 then
      return limit_exceeding, nil, "wrong value for delay_ms: " .. delay_ms
    end
  end

  return limit_exceeding, delay_ms, nil
end

-- process_sample first checks if limit exceeding for the given sample.
-- If so then, it calculates for how long this sample
-- should be delayed/rejected and returns estimated total count for
-- the current window for this sample along with suggested delay time to bring
-- the rate down below the limit.
-- If limit is not exceeding yet, it increments the counter corresponding
-- to the sample in the current window. Finally it checks if the limit is
-- exceeding again. This check is necessary because between the first check and
-- increment another sliding window instances might have processed enough
-- occurences of this sample to exceed the limit. Therefore if this check shows
-- that the limit is exceeding then we again calculate necessary delay.
--
-- Return values: estimated_count, delay, err
-- `estimated_count` - this is what the algorithm expects number of occurences
-- will be for the sample by the end of current window. It is calculated based
-- on the rate from previous window and extrapolated to the current window.
-- If estimated_count is bigger than the configured limit, then the function
-- will also return delay > 0 to suggest that the sample has to be throttled.
-- `delay`           - this is either strictly bigger than 0 in case limit is
-- exceeding, or nil in case rate of occurences of the sample is under the
-- limit. The unit is second.
-- `err`             - in case there is a problem with processing the sample
-- this will be a string explaining the problem. In all other cases it is nil.
function _M.process_sample(self, sample)
  local now_ms = ngx_now() * 1000

  local counter_key = get_counter_key(self, sample, now_ms)

  local expiry = self.window_size * 2 / 1000 --seconds

  return self.store:incr(counter_key, 1, expiry)
end

return _M
