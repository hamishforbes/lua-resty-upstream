#lua-resty-upstream

Upstream connection load balancing and failover module

#Table of Contents

* [Status](#status)
* [Overview](#overview)
* [upstream.socket](#upstream.socket)
    * [new](#new)
    * [connect](#connect)
    * [postProcess](#postProcess)
    * [getPools](#getPools)
    * [savePools](#savePools)
    * [sortPools](#sortPools)
* [upstream.api](#upstream.api)
    * [new](#upstream_new)
    * [setMethod](#setMethod)
    * [createPool](#createPool)
    * [setPriority](#setPriority)
    * [addHost](#addHost)
    * [removeHost](#removeHost)
    * [hostDown](#hostDown)
    * [hostUp](#hostUp)

#Status

Very early, not ready for production

#Overview

Create a lua [shared dictionary](https://github.com/chaoslawful/lua-nginx-module#lua_shared_dict).
Define your upstream pools and hosts in init_by_lua, this will be saved into the shared dictionary.

Use the `connect` method to return a connected tcp [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp).

Alternatively pass in a resty module (e.g [lua-resty-redis](https://github.com/agentzh/lua-resty-redis)) that implements `connect()` and `set_timeout()`.

Call `postProcess` in log_by_lua to handle failed hosts etc.

Use `resty.upstream.api` to modify upstream configuration during init or runtime, this is recommended!

```lua
lua_shared_dict my_upstream 1m;
init_by_lua '
    upstream_socket  = require("resty.upstream.socket")
    upstream_api = require("resty.upstream.api")

    upstream, configured = socket_upstream:new("my_upstream")
    api = upstream_api:new(upstream)

    if not configured then -- Only reconfigure on start, shared mem persists across a HUP
        api:createPool({id = "primary", timeout = 100})
        api:setPriority("primary", 0)
        api:setMethod("primary", "round_robin")
        api:addHost("primary", { id="a", host = "127.0.0.1", port = "80", weight = 10 })
        upstream:addHost("primary", { id="b", host = "127.0.0.1", port = "81",  weight = 10 })

        api:createPool({id = "dr"})
        api:setPriority("dr", 10)
        api:addHost("dr", { host = "127.0.0.1", port = "82", weight = 5 })
        api:addHost("dr", { host = "127.0.0.1", port = "83", weight = 10 })

        api:createPool({id = "test", priority = 5})
        api:addHost("primary", { id="c", host = "127.0.0.1", port = "82", weight = 10 })
        api:addHost("primary", { id="d", host = "127.0.0.1", port = "83", weight = 10 })
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

# upstream.socket

## new
`syntax: upstream, configured = socket_upstream:new(dictionary)`

Returns a new upstream object using the provided dictionary name.
When called in init_by_lua returns an additional variable if the dictionary already contains configuration.

## connect
`syntax: ok, err = upstream:connect(client?)`

Attempts to connect to a host in the defined pools in priority order using the selected load balancing method.
Returns a connected socket and a table containing the connected `host` and `pool` or nil and an error message.

When passed a [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp) or resty module it will return the same object after successful connection or nil.

```lua
require('resty.redis')
local redis = resty_redis.new()

local redis, err = upstream:connect(redis)

if not redis then
    ngx.log(ngx.ERR, err)
    ngx.status = 500
    return ngx.exit(ngx.status)
end

ngx.log(ngx.info, 'Connected to ' .. err.host.host .. ':' .. err.host.port)
local ok, err = redis:get('key')
```

## postProcess
`syntax: ok, err = upstream:postProcess()`

Processes any failed or recovered hosts from the current request


## getPools
`syntax: pools = usptream:getPools()`

Returns a table containing the current pool and host configuration.
e.g.
```lua
{
    primary = {
        up = true,
        method = 'round_robin',
        timeout = 100,
        priority = 0,
        hosts = {
            web01 = {
                host = "127.0.0.1",
                weight = 10,
                port = "80",
                lastfail = 0,
                failcount = 0,
                up = true
            }
            web02 = {
                host = "127.0.0.1",
                weight = 10,
                port = "80",
                lastfail = 0,
                failcount = 0,
                up = true
            }
        }
    },
    secondary = {
        up = true,
        method = 'round_robin',
        timeout = 2000,
        priority = 10,
        hosts = {
            dr01 = {
                id = "dr01",
                host = "10.10.10.1",
                weight = 10,
                port = "80",
                lastfail = 0,
                failcount = 0,
                up = true
            }

        }
    },
}
```

## savePools
`syntax: ok, err = upstream:savePools(pools)`

Saves a table of pools to the shared dictionary, `pools` must be in the same format as returned from `getPools`

## sortPools
`syntax: ok, err = upstream:sortPools(pools)`

Generates a priority order in the shared dictionary based on the table of pools provided



# upstream.api
These functions allow you to dynamically reconfigure upstream pools and hosts

## new
`syntax: api, err = upstream_api:new(upstream)`

Returns a new api object using the provided upstream object.


## setMethod
`syntax: ok, err = api:setMethod(poolid, method)`

Sets the load balancing method for the specified pool.
Currently only randomised round robin is supported.

## createPool
`syntax: ok, err = api:createPool(pool)`

Creates a new pool from a table of options, `pool` must contain at least 1 key `id` which must be unique within the current upstream object.
Other valid options are `method`, `timeout`, and `priority`.
Hosts cannot be defined at this point.

Default pool values
```lua
{ method = 'round_robin', timeout = 2000, priority = 0 }
```

## setPriority
`syntax: ok, err = api:setPriority(poolid, priority)`

Priority must be a number, returns nil on error.

## addHost
`syntax: ok, err = api:addHost(poolid, host)`

Takes a pool ID and a table of options, `host` must contain at least `host`.
If the host ID is not specified it will be a numeric index based on the number of hosts in the pool.

Defaults:
```lua
{ host = '', port = 80, weight = 0}
```

## removeHost
`syntax: ok, err = api:removeHost(poolid, host)`

Takes a poolid and a hostid to remove from the pool

## hostDown
`syntax: ok,err = api:hostDown(poolid, host)`

Manually marks a host as down, this host will *not* be revived automatically.

## hostUp
`syntax: ok,err = api:hostUp(poolid, host)`

Manually restores a dead host to the pool


## TODO
 * IP based sticky sessions
 * HTTP Specific options
     * Active healthchecks
     * Cookie based sticky sessions
