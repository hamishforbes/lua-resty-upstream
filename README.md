# lua-resty-upstream
Upstream connection load balancing and failover module

## Dictionary
lua_shared_dict my_upstream 1m;

## init_by_lua
```lua
socket_upstream  = require("resty.socket-upstream")

upstream, configured = socket_upstream:new("my_upstream")
if not configured then -- Only reconfigure on start, shared mem persists across a HUP

    upstream:createPool({id = "primary", timeout = 100, keepalive = 256})
    upstream:setPriority("primary", 0)
    upstream:setMethod("primary", "round_robin")
    upstream:addHost("primary", { id="a", host = "127.0.0.1", port = "80", weight = 10 })
    upstream:addHost("primary", { id="b", host = "127.0.0.1", port = "81",  weight = 10 })

    upstream:createPool({id = "dr", keepalive = 0})
    upstream:setPriority("dr", 10)
    upstream:addHost("dr", { host = "127.0.0.1", port = "82", weight = 5 })
    upstream:addHost("dr", { host = "127.0.0.1", port = "83", weight = 10 })

    upstream:createPool({id = "test", priority = 5})
    upstream:addHost("primary", { id="c", host = "127.0.0.1", port = "82", weight = 10 })
    upstream:addHost("primary", { id="d", host = "127.0.0.1", port = "83", weight = 10 })
end
```

## content_by_lua
```lua
local sock, err = upstream:connect()

```

## log_by_lua
```
upstream:postProcess()
```