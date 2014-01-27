local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local str_format = string.format

local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }

local default_pool = {
    up = true,
    method = 'round_robin',
    timeout = 2000, -- socket connect timeout
    priority = 0,
    failed_timeout = 60,
    max_fails = 3,
    hosts = {}
}

local optional_pool = {
    ['read_timeout'] = true, -- socket timeout after connect
    ['keepalive_timeout'] = true,
    ['keepalive_pool'] = true,
    ['status_codes'] = true
}

local numerics = {
    'priority',
    'timeout',
    'failed_timeout',
    'max_fails',
    'read_timeout',
    'keepalive_timeout',
    'keepalive_pool'
}

local default_host = {
    host = '',
    port = 80,
    up = true,
    weight = 0,
    failcount = 0,
    lastfail = 0
}

local optional_host = {
    ['healthcheck'] = true
}

function _M.new(_, upstream)

    local self = {
        upstream = upstream
    }
    return setmetatable(self, mt)
end


function _M.get_pools(self, ...)
    return self.upstream:get_pools(...)
end


function _M.save_pools(self, ...)
    return self.upstream:save_pools(...)
end


function _M.sort_pools(self, ...)
    return self.upstream:sort_pools(...)
end


function _M.set_method(self, poolid, method)
    local available_methods = self.upstream.available_methods

    if not available_methods[method] then
        return nil, 'Method not found'
    end

    local pools = self:get_pools()
    if not pools[poolid] then
        return nil, 'Pool not found'
    end
    pools[poolid].method = method
    ngx_log(ngx_debug, str_format('%s method set to %s', poolid, method))
    return self:save_pools(pools)
end


local function validate_pool(opts, pools, methods)
    if pools[opts.id] then
        return nil, 'Pool exists'
    end

    for _,key in ipairs(numerics) do
        if opts[key] and type(opts[key]) ~= "number" then
            return nil, key.. " must be a number"
        end
    end
    if opts.method and not methods[opts.method] then
        return nil, 'Method not available'
    end
    return true
end


function _M.create_pool(self, opts)
    local poolid = opts.id
    if not poolid then
        return nil, 'No ID set'
    end

    local pools = self:get_pools()

    local ok, err = validate_pool(opts, pools, self.upstream.available_methods)
    if not ok then
        return ok, err
    end

    local pool = {}
    for k,v in pairs(default_pool) do
        local val = opts[k] or v
        -- Can't set 'up' or 'hosts' values here
        if k == 'up' or k == 'hosts' then
            val = v
        end
        pool[k] = val
    end
    -- Allow additional optional values
    for k,v in pairs(optional_pool) do
        if opts[k] then
            pool[k] = opts[k]
        end
    end
    pools[poolid] = pool

    local ok, err = self:save_pools(pools)
    if not ok then
        return ok, err
    end
    ngx_log(ngx_debug, 'Created pool '..poolid)
    return self:sort_pools(pools)
end


function _M.set_priority(self, poolid, priority)
    if type(priority) ~= 'number' then
        return nil, 'Priority must be a number'
    end

    local pools = self:get_pools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end

    pools[poolid].priority = priority

    local ok, err = self:save_pools(pools)
    if not ok then
        return ok, err
    end
    ngx_log(ngx_debug, str_format('%s priority set to %d', poolid, priority))
    return self:sort_pools(pools)
end


function _M.set_weight(self, poolid, hostid, weight)
    if type(weight) ~= 'number' or weight < 0 then
        return nil, 'Weight must be a positive number'
    end

    local pools = self:get_pools()
    if not pools then
        return nil, 'No pools found'
    end

    local pool = pools[poolid]
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end

    local host_idx = self.upstream.get_host_idx(host, pool.hosts)
    if not host_idx then
        return nil, 'Host not found'
    end
    pool.hosts[host_idx].weight = weight

    ngx_log(ngx_debug,
        str_format('Host weight "%s" in "%s" set to %d', hostid, poolid, weight)
    )
    return self:save_pools(pools)
end


function _M.add_host(self, poolid, host)
    local pools = self:get_pools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end
    local pool = pools[poolid]

    -- Validate host definition and set defaults
    local hostid = host['id']
    if not hostid then
        hostid = #pool.hosts+1
    else
        for _, h in pairs(pool.hosts) do
            if h.id == hostid then
                hostid = #pool.hosts+1
                break
            end
        end
    end

    local new_host = {}
    for key, default in pairs(default_host) do
        local val = host[key] or default
        new_host[key] = val
    end
    new_host.id = hostid

    pool.hosts[#pool.hosts+1] = new_host

    ngx_log(ngx_debug, str_format('Host "%s" added to  "%s"', hostid, poolid))
    return self:save_pools(pools)
end


function _M.remove_host(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:get_pools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end

    local host_idx = self.upstream.get_host_idx(host, pool.hosts)
    if not host_idx then
        return nil, 'Host not found'
    end
    pool.hosts[host_idx] = nil

    ngx_log(ngx_debug, str_format('Host "%s" removed from "%s"', host, poolid))
    return self:save_pools(pools)
end


function _M.down_host(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:get_pools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool '.. poolid ..' not found'
    end
    local host_idx = self.upstream.get_host_idx(host, pool.hosts)
    if not host_idx then
        return nil, 'Host not found'
    end
    local host = pool.hosts[host_idx]

    host.up = false
    host.lastfail = 0
    host.failcount = 0
    ngx_log(ngx_debug,
        str_format('Host "%s" in Pool "%s" is manually down',
            host.id,
            poolid
        )
    )

    return self:save_pools(pools)
end


function _M.up_host(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:get_pools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end
    local host_idx = self.upstream.get_host_idx(host, pool.hosts)
    if not host_idx then
        return nil, 'Host not found'
    end
    local host = pool.hosts[host_idx]

    host.up = true
    host.lastfail = 0
    host.failcount = 0
    ngx_log(ngx_debug,
        str_format('Host "%s" in Pool "%s" is manually up',
            host.id,
            poolid
        )
    )

    return self:save_pools(pools)
end

return _M