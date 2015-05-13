local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local str_format = string.format
local tostring = tostring

local _M = {
    _VERSION = '0.03',
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
    'keepalive_pool',
    'port',
    'weight',
    'failcount',
    'lastfail'
}

local default_host = {
    host = '',
    port = 80,
    up = true,
    weight = 1,
    failcount = 0,
    lastfail = 0
}

local http_healthcheck_required = {
    interval = 60, -- Run every time background function runs if nil
    last_check = 0,
}

local optional_host = {
    ['healthcheck'] = false
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


function _M.get_locked_pools(self, ...)
    return self.upstream:get_locked_pools(...)
end


function _M.unlock_pools(self, ...)
    return self.upstream:unlock_pools(...)
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

    if not poolid then
        return nil, 'No pool ID specified'
    end
    poolid = tostring(poolid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    if not pools[poolid] then
        self:unlock_pools()
        return nil, 'Pool not found'
    end
    pools[poolid].method = method
    ngx_log(ngx_debug, str_format('%s method set to %s', poolid, method))

    local ok, err = self:save_pools(pools)
    if not ok then
        ngx_log(ngx_ERR, "Error saving pools for upstream ", self.id, " ", err)
    end

    self:unlock_pools()

    return ok, err
end


local function validate_pool(opts, pools, methods)
    if pools[tostring(opts.id)] then
        return nil, 'Pool exists'
    end

    for _,key in ipairs(numerics) do
        if opts[key] and type(opts[key]) ~= "number" then
            local tmp = tonumber(opts[key])
            if not tmp then
                return nil, key.. " must be a number"
            else
                opts[key] = tmp
            end
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
        return nil, 'Pools must have an ID'
    end
    poolid = tostring(poolid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end

    local ok, err = validate_pool(opts, pools, self.upstream.available_methods)
    if not ok then
        self:unlock_pools()
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
        self:unlock_pools()
        return ok, err
    end

    -- Add some operational data per pool
    self.upstream.operational_data[poolid] = {}

    ngx_log(ngx_debug, 'Created pool '..poolid)

    local ok, err = self:sort_pools(pools)
    self:unlock_pools()
    return ok, err
end


function _M.set_priority(self, poolid, priority)
    if type(priority) ~= 'number' then
        return nil, 'Priority must be a number'
    end
    if not poolid then
        return nil, 'No pool ID specified'
    end
    poolid = tostring(poolid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    if pools[poolid] == nil then
        self:unlock_pools()
        return nil, 'Pool not found'
    end

    pools[poolid].priority = priority

    local ok, err = self:save_pools(pools)
    if not ok then
        self:unlock_pools()
        return ok, err
    end
    ngx_log(ngx_debug, str_format('%s priority set to %d', poolid, priority))

    local ok, err = self:sort_pools(pools)
    self:unlock_pools()
    return ok, err
end


function _M.set_weight(self, poolid, hostid, weight)
    if type(weight) ~= 'number' or weight < 0 then
        return nil, 'Weight must be a positive number'
    end
    if not poolid or not hostid then
        return nil, 'Pool or host id not specified'
    end
    poolid = tostring(poolid)
    hostid = tostring(hostid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end

    local pool = pools[poolid]
    if pools[poolid] == nil then
        self:unlock_pools()
        return nil, 'Pool not found'
    end

    local host_idx = self.upstream.get_host_idx(hostid, pool.hosts)
    if not host_idx then
        self:unlock_pools()
        return nil, 'Host not found'
    end
    pool.hosts[host_idx].weight = weight

    ngx_log(ngx_debug,
        str_format('Host weight "%s" in "%s" set to %d', hostid, poolid, weight)
    )

    local ok,err = self:save_pools(pools)
    self:unlock_pools()
    return ok, err
end


function _M.add_host(self, poolid, host)
    if not host then
        return nil, 'No host specified'
    end
    if not poolid then
        return nil, 'No pool ID specified'
    end
    poolid = tostring(poolid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    if pools[poolid] == nil then
        self:unlock_pools()
        return nil, 'Pool not found'
    end
    local pool = pools[poolid]

    -- Validate host definition and set defaults
    local hostid = host['id']
    if not hostid then
        hostid = #pool.hosts+1
    else
        hostid = tostring(hostid)
        for _, h in pairs(pool.hosts) do
            if h.id == hostid then
                self:unlock_pools()
                return nil, 'Host ID already exists'
            end
        end
    end
    hostid = tostring(hostid)

    local new_host = {}
    for key, default in pairs(default_host) do
        local val = host[key]
        if val == nil then val = default end
        new_host[key] = val
    end
    for key, default in pairs(optional_host) do
        if host[key] then
            new_host[key] = host[key]
        end
    end
    new_host.id = hostid

    for _,key in ipairs(numerics) do
        if new_host[key] and type(new_host[key]) ~= "number" then
            local tmp = tonumber(new_host[key])
            if not tmp then
                self:unlock_pools()
                return nil, key.. " must be a number"
            else
                new_host[key] = tmp
            end
        end
    end

    -- Set http healthcheck minimum attributes
    local http_check = new_host.healthcheck
    if http_check then
        if http_check == true then
            new_host.healthcheck = http_healthcheck_required
        else
            for k,v in pairs(http_healthcheck_required) do
                if not http_check[k] then
                    http_check[k] = v
                end
            end
        end
    end

    pool.hosts[#pool.hosts+1] = new_host

    ngx_log(ngx_debug, str_format('Host "%s" added to  "%s"', hostid, poolid))
    local ok, err = self:save_pools(pools)
    self:unlock_pools()
    return ok,err
end


function _M.remove_host(self, poolid, hostid)
    if not poolid or not hostid then
        return nil, 'Pool or host id not specified'
    end
    poolid = tostring(poolid)
    hostid = tostring(hostid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    local pool = pools[poolid]
    if not pool then
        self:unlock_pools()
        return nil, 'Pool not found'
    end

    local host_idx = self.upstream.get_host_idx(hostid, pool.hosts)
    if not host_idx then
        self:unlock_pools()
        return nil, 'Host not found'
    end
    pool.hosts[host_idx] = nil

    ngx_log(ngx_debug, str_format('Host "%s" removed from "%s"', hostid, poolid))
    local ok, err = self:save_pools(pools)
    self:unlock_pools()
    return ok, err
end


function _M.down_host(self, poolid, hostid)
    if not poolid or not hostid then
        return nil, 'Pool or host id not specified'
    end
    poolid = tostring(poolid)
    hostid = tostring(hostid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    local pool = pools[poolid]
    if not pool then
        self:unlock_pools()
        return nil, 'Pool '.. poolid ..' not found'
    end
    local host_idx = self.upstream.get_host_idx(hostid, pool.hosts)
    if not host_idx then
        self:unlock_pools()
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

    local ok, err = self:save_pools(pools)
    self:unlock_pools()
    return ok, err
end


function _M.up_host(self, poolid, hostid)
    if not poolid or not hostid then
        return nil, 'Pool or host id not specified'
    end
    poolid = tostring(poolid)
    hostid = tostring(hostid)

    local pools, err = self:get_locked_pools()
    if not pools then
        return nil, err
    end
    local pool = pools[poolid]
    if not pool then
        self:unlock_pools()
        return nil, 'Pool not found'
    end
    local host_idx = self.upstream.get_host_idx(hostid, pool.hosts)
    if not host_idx then
        self:unlock_pools()
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

    local ok, err = self:save_pools(pools)
    self:unlock_pools()
    return ok, err
end

return _M