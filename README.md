#lua-resty-upstream

Upstream connection load balancing and failover module

#Table of Contents

* [Status](#status)
* [Overview](#overview)
* [upstream.socket](#upstream.socket)
    * [new](#new)
    * [init_background_thread](#init_background_thread)
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
* [upstream.http](#upstream.http)
    * [status_codes](#status_codes)
    * [healthchecks](#healthchecks)
    * [new](#new-2)
    * [init_background_thread](#init_background_thread-1)
    * [request](#request)
    * [set_keepalive](#set_keepalive)
    * [get_reused_times](#get_reused_times)
    * [close](#close)

#Status

Experimental, API may change without warning.

Requires ngx_lua > 0.9.5

#Overview

Create a lua [shared dictionary](https://github.com/chaoslawful/lua-nginx-module#lua_shared_dict).
Define your upstream pools and hosts in init_by_lua, this will be saved into the shared dictionary.

Use the `connect` method to return a connected tcp [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp).

Alternatively pass in a resty module (e.g [lua-resty-redis](https://github.com/agentzh/lua-resty-redis) or [lua-resty-http](https://github.com/pintsize/lua-resty-http)) that implements `connect()` and `set_timeout()`.

Call `post_process` in log_by_lua to handle failed hosts etc.

Use `resty.upstream.api` to modify upstream configuration during init or runtime, this is recommended!

`resty.upstream.http`  wraps the [lua-resty-http](https://github.com/pintsize/lua-resty-http) from @pintsized.

It allows for failover based on HTTP status codes as well as socket connection status.


```lua
lua_shared_dict my_upstream_dict 1m;
init_by_lua '
    upstream_socket  = require("resty.upstream.socket")
    upstream_api = require("resty.upstream.api")

    upstream, configured = socket_upstream:new("my_upstream_dict")
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

init_worker_by_lua 'upstream:init_background_thread()';

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
`syntax: upstream, configured = upstream_socket:new(dictionary, id?)`

Returns a new upstream object using the provided dictionary name.
When called in init_by_lua returns an additional variable if the dictionary already contains configuration.
Takes an optional id parameter, this *must* be unique if multiple instances of upstream.socket are using the same dictionary.

### init_background_thread
`syntax: ok, err = upstream:init_background_thread()`

Initialises the background thread, should be called in `init_worker_by_lua`

### connect
`syntax: ok, err = upstream:connect(client?)`

Attempts to connect to a host in the defined pools in priority order using the selected load balancing method.
Returns a connected socket and a table containing the connected `host`, `poolid` and `pool` or nil and an error message.

When passed a [socket](https://github.com/chaoslawful/lua-nginx-module#ngxsockettcp) or resty module it will return the same object after successful connection or nil.

```lua
resty_redis = require('resty.redis')
local redis = resty_redis.new()

local redis, e = upstream:connect(redis)

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
                up = true,
                healthcheck = true
            }
            web02 = {
                host = "127.0.0.1",
                weight = 10,
                port = "80",
                lastfail = 0,
                failcount = 0,
                up = true,
                healthcheck = { path = '/check' }
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


# upstream.api
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
Other valid options are `method`, `timeout`, `priority`, `read_timeout`, `keepalive_timeout`, `keepalive_pool` and `status_codes`.
Hosts cannot be defined at this point.

Note: IDs are converted to a string by this function

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

Note: IDs are converted to a string by this function

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

# upstream.http

Functions for making http requests to upstream hosts.

### status_codes
This pool option is an array of status codes that indicate a failed request.

```lua
{
    ['5xx'] = true,
    ['400'] = true
}
```

### healthchecks

Active background healthchecks can be enabled by adding the `healthcheck` parameter to a host.

The default check is a `GET` request for `/`.

The `healthcheck` parameter can also be a table of parameters valid for lua-resty-http's [request](https://github.com/pintsized/lua-resty-http#request) method.

Failure for the background check is according to the same parameters as for a frontend request.

```lua
-- Custom check parameters
api:add_host("primary", {
     host = 123.123.123.123,
     port = 80,
     healthcheck = {
        path = "/check",
        headers = {
            ["Host"] = "domain.com",
            ["Accept-Encoding"] = "gzip"
        }
     }
})

-- Default check parameters
api:add_host("primary", {host = 123.123.123.123, port = 80, healthcheck = true})

```

### new
`syntax: httpc, err = upstream_http:new(upstream)`

Returns a new http upstream object using the provided upstream object.

### init_background_thread
`syntax: ok, err = upstream_http:init_background_thread()`

Initialises the background thread, should be called in `init_worker_by_lua`.

Do *not* call the `init_background_thread` method in `upstream.socket` if using the `upstream.http` background thread

### request
`syntax: res, conn_info = upstream_api:request(params)`

Takes the same parameters as lua-resty-http's [request](https://github.com/pintsized/lua-resty-http#request) method.

On a successful request returns the lua-resty-http object and a table containing the connected host and pool.

If the request failed returns nil and a table describing the error and suggested http status code
```lua
{ err = error_message, status = (502 or 504) }
```

### set_keepalive
`syntax: ok, err = upstream_http:set_keepalive()`

Passes the keepalive timeout / pool from the pool configuration through to the lua-resty-http `set_keepalive` method.

### get_reused_times
`syntax: ok, err = upstream_http:get_reused_times()`

Passes through to the lua-resty-http `get_reused_times` method.

### close
`syntax: ok, err = upstream_http:close()`

Passes through to the lua-resty-http `close` method.



## TODO
 * IP based sticky sessions
 * Slow start - recovered hosts have lower weighting
 * Active TCP healthchecks
 * HTTP Specific options
     * Cookie based sticky sessions
