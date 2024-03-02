local key = ARGV[1]
local member = ARGV[2]
local increment_amount_ms = tonumber(ARGV[3])
local now_epoch_ms = tonumber(ARGV[4])

-- first attempt a zincrby - if the result is the increment amount, we just added it and need to zadd instead
local result_amount = redis.call("HINCRBY", key, member, increment_amount_ms)

if (result_amount == increment_amount or result_amount < (increment_amount_ms + now_epoch_ms))
then
  -- overwrite the previous write with the fallback value
  redis.call("HSET", key, member, increment_amount_ms + now_epoch_ms)
  return increment_amount_ms + now_epoch_ms
end

return result_amount
