local available_numbers_key = ARGV[1]
local next_sendable_key = ARGV[2]
local daily_contact_limit = tonumber(ARGV[3])
local too_far_in_future_timestamp = tonumber(ARGV[4])

local iteration = 0

local zrangebyscore_result = nil
local next_candidate = nil
local sendable_at = nil


while (true)
do
  -- get next lowest to send from today
  -- redis.log(redis.LOG_WARNING, "Searching within: " .. daily_contact_limit .. ", " .. iteration)
  zrangebyscore_result = redis.call("ZRANGEBYSCORE", available_numbers_key, 0, daily_contact_limit, "LIMIT", iteration, 1)
  next_candidate = zrangebyscore_result[1]

  -- redis.log(redis.LOG_WARNING, "Next candidate: " .. tostring(next_candidate))
  if (next_candidate == nil)
  then
    do
      return next_candidate
    end
  end

  sendable_at = redis.call("HGET", next_sendable_key, next_candidate)

  -- redis.log(redis.LOG_WARNING, "Sendable at: " .. tostring(sendable_at) .. " and too far in future is " .. tostring(too_far_in_future_timestamp))
  if (sendable_at == nil or sendable_at == false)
  then
    do
      return next_candidate
    end
  end

  sendable_at = tonumber(sendable_at)

  if (sendable_at <= too_far_in_future_timestamp)
  then
    do
      -- redis.log(redis.LOG_WARNING, "Using number " .. next_candidate)
      return next_candidate
    end
  end

  -- redis.log(redis.LOG_WARNING, "Cannot use number")
  iteration = iteration + 1
end
