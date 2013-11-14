#lua-resty-upstream

Upstream connection load balancing and failover module

#Table of Contents

* [Status](#status)
* [Overview](#overview)
* [upstream.socket](#upstream.socket)
    * [new](#new)
    * [connect](#connect)
    * [post_process](#post_process)
    * [get_pools](#get_pools)
    * [save_pools](#save_pools)
    * [sort_pools](#sort_pools)
* [upstream.api](#upstream.api)
    * [new](#new-1)
    * [set_method](#set_method)
    * [create_pool](#create_pool)
    * [set_priority](#set_priority)
    * [add_host](#add_host)
    * [remove_host](#remove_host)
    * [down_host](#down_host)
    * [up_host](#up_host)

#Status

Very early, not ready for production

#Overview

Create a lua [shared dictionary](https://github.com/chaoslawful/lua-nginx-module#lua_shared_dict).
Define your upstream pools and hosts in init_by_lua, this will be saved into the shared dictionary.

Use the `connect` method to return a connected tcp [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp).

Alternatively pass in a resty module (e.g [lua-resty-redis](https://github.com/agentzh/lua-resty-redis)) that implements `connect()` and `set_timeout()`.

Call `post_process` in log_by_lua to handle failed hosts etc.

Use `resty.upstream.api` to modify upstream configuration during init or runtime, this is recommended!

```lua
lua_shared_dict my_upstream 1m;
init_by_lua '
    upstream_socket  = require("resty.upstream.socket")
    upstream_api = require("resty.upstream.api")

    upstream, configured = socket_upstream:new("my_upstream")
    api = upstream_api:new(upstream)

    if not configured then -- Only reconfigure on start, shared mem persists across a HUP
        api:create_pool({id = "primary", timeout = 100})
        api:set_priority("primary", 0)
        api:set_method("primary", "round_robin")
        api:add_host("primary", { id="a", host = "127.0.0.1", port = "80", weight = 10 })
        api:add_host("primary", { id="b", host = "127.0.0.1", port = "81",  weight = 10 })

        api:create_pool({id = "dr"})
        api:set_priority("dr", 10)
        api:add_host("dr", { host = "127.0.0.1", port = "82", weight = 5 })
        api:add_host("dr", { host = "127.0.0.1", port = "83", weight = 10 })

        api:create_pool({id = "test", priority = 5})
        api:add_host("primary", { id="c", host = "127.0.0.1", port = "82", weight = 10 })
        api:add_host("primary", { id="d", host = "127.0.0.1", port = "83", weight = 10 })
    end
';

server {

    location / {
        content_by_lua '
            local sock, err = upstream:connect()
        ';

        log_by_lua 'upstream:post_process()';
    }

}
```

# upstream.socket

### new
`syntax: upstream, configured = upstream_socket:new(dictionary)`

Returns a new upstream object using the provided dictionary name.
When called in init_by_lua returns an additional variable if the dictionary already contains configuration.

### connect
`syntax: ok, err = upstream:connect(client?)`

Attempts to connect to a host in the defined pools in priority order using the selected load balancing method.
Returns a connected socket and a table containing the connected `host`, `poolid` and `pool` or nil and an error message.

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

### post_process
`syntax: ok, err = upstream:post_process()`

Processes any failed or recovered hosts from the current request


### get_pools
`syntax: pools = usptream:get_pools()`

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

### save_pools
`syntax: ok, err = upstream:save_pools(pools)`

Saves a table of pools to the shared dictionary, `pools` must be in the same format as returned from `get_pools`

### sort_pools
`syntax: ok, err = upstream:sort_pools(pools)`

Generates a priority order in the shared dictionary based on the table of pools provided



### upstream.api
These functions allow you to dynamically reconfigure upstream pools and hosts

### new
`syntax: api, err = upstream_api:new(upstream)`

Returns a new api object using the provided upstream object.


### set_method
`syntax: ok, err = api:set_method(poolid, method)`

Sets the load balancing method for the specified pool.
Currently only randomised round robin is supported.

### create_pool
`syntax: ok, err = api:create_pool(pool)`

Creates a new pool from a table of options, `pool` must contain at least 1 key `id` which must be unique within the current upstream object.
Other valid options are `method`, `timeout`, and `priority`.
Hosts cannot be defined at this point.

Default pool values
```lua
{ method = 'round_robin', timeout = 2000, priority = 0 }
```

### set_priority
`syntax: ok, err = api:set_priority(poolid, priority)`

Priority must be a number, returns nil on error.

### add_host
`syntax: ok, err = api:add_host(poolid, host)`

Takes a pool ID and a table of options, `host` must contain at least `host`.
If the host ID is not specified it will be a numeric index based on the number of hosts in the pool.

Defaults:
```lua
{ host = '', port = 80, weight = 0}
```

### remove_host
`syntax: ok, err = api:remove_host(poolid, host)`

Takes a poolid and a hostid to remove from the pool

### down_host
`syntax: ok,err = api:down_host(poolid, host)`

Manually marks a host as down, this host will *not* be revived automatically.

### up_host
`syntax: ok,err = api:up_host(poolid, host)`

Manually restores a dead host to the pool

## TODO
 * IP based sticky sessions
 * HTTP Specific options
     * Active healthchecks
     * Cookie based sticky sessions
