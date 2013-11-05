# lua-resty-upstream
Upstream connection load balancing and failover module

## Status
Very early, not ready for production

## Overview
Create a lua [shared dictionary](https://github.com/chaoslawful/lua-nginx-module#lua_shared_dict)
Define your upstream pools and hosts in init_by_lua, this will be saved into the shared dictionary

Use the `connect` method to return a connected tcp [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp)

Call `postProcess` in log_by_lua to handle failed hosts etc

```lua
lua_shared_dict my_upstream 1m;
init_by_lua '
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
';

server {

    location / {
        content_by_lua '
            local sock, err = upstream:connect()
        ';

        log_by_lua 'upstream:postProcess()';
    }

}
```

## Config API
These functions allow you to dynamically reconfigure upstream pools and hosts

### new
`syntax: upstream, configured = socket_upstream:new(dictionary)'
Returns a new upstream object using the provided dictionary name.
When called in init_by_lua returns an additional variable if the dictionary already contains configuration.

### getPools
`syntax: pools = usptream:getPools()`
Returns a table containing the current pool and host configuration.
e.g.
```lua
{
    primary = {
        up = true,
        method = 'round_robin',
        timeout = 100,
        keepalive = 128,
        priority = 0,
        hosts = {
            web01 = { id = "web01", host = "127.0.0.1", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }
            web02 = { id = "web01", host = "127.0.0.2", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }
        }
    },
    secondary = {
        up = true,
        method = 'round_robin',
        timeout = 2000,
        keepalive = 0,
        priority = 10,
        hosts = {
            dr01 = { id = "dr01", host = "10.10.10.1", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }
            dr02 = { id = "dr01", host = "10.10.10.2", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }
        }
    },
}
```

### setMethod
`syntax: ok, err = upstream:setMethod(poolid, method)`
Sets the load balancing method for the specified pool.
Currently only randomised round robin is supported.

### createPool
`syntax: ok, err = upstream:createPool(pool)`
Creates a new pool from a table of options, `pool` must contain at least 1 key `id` which must be unique within the current upstream object.
Other valid options are `method`, `timeout`, `keepalive` and `priority`.
Hosts cannot be defined at this point.

Default pool values
```lua
{ method = 'round_robin', timeout = 2000, keepalive = 0, priority = 0 }
```

### setPriority
`syntax: ok, err = upstream:setPriority(poolid, priority)`
Priority must be a number, returns nil on error.

### addHost
`syntax: ok, err = upstream:addHost(poolid, host)`
Takes a pool ID and a table of options, `host` must contain at least `host`.
If the host ID is not specified it will be a numeric index based on the number of hosts in the pool.

Defaults:
```lua
{ host = '', port = 80, weight = 0}

```

### postProcess
`syntax: ok, err = upstream:postProcess()`
Processes any failed or recovered hosts from the current request


## Connection API

### connect
`syntax: ok, err = upstream:connect()`
Attempts to connect to a host in the defined pools in priority order using the selected load balancing method
Returns a connected socket or nil and an error

## TODO
 * Additional configuration methods (`setWeight`, `hostUp`, `hostDown`)
 * Use [ngx.timer.at](https://github.com/chaoslawful/lua-nginx-module#ngxtimerat) to background a thread for processing of host states
 * Logging variables, e.g. host id/pool/addr/port connected to
 * HTTP Specific options
     * Active healthchecks
     * Sticky session load balancing, IP and cookie
