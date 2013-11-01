local ngx_socket_tcp = ngx.socket.tcp
local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local str_format = string.format
local tbl_insert = table.insert
local tbl_sort = table.sort
local randomseed = math.randomseed
local random = math.random
local now = ngx.now
local update_time = ngx.update_time
local shared = ngx.shared
local phase = ngx.get_phase
local loadstring = loadstring
local serpent = require('serpent')
local serialise = serpent.dump


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }

local default_pool = {
    up = true,
    method = 'round_robin',
    keepalive = 0,
    timeout = 2000,
    keepalive = 0,
    priority = 0,
    hosts = {}
}

local default_host = {
    host = '',
    port = 80,
    up = true,
    weight = 0,
    failcount = 0,
    lastfail = 0
}

local available_methods = { }

local failed_timeout = 60 -- Recheck a down host every 60s
local max_fails = 3

local pools_key = 'pools'
local priority_key = 'priority_index'


local function sortPools(self, pools)
    -- Create a table of priorities and a map back to the pool
    local priorities = {}
    local map = {}
    for id,p in pairs(pools) do
        map[p.priority] = id
        tbl_insert(priorities, p.priority)
    end
    tbl_sort(priorities)

    local sorted_pools = {}
    for k,pri in ipairs(priorities) do
        tbl_insert(sorted_pools, map[pri])
    end

    local serialised = serialise(sorted_pools)
    return self.dict:set(priority_key, serialised)
end

local function savePools(self, pools)
    local serialised = serialise(pools)
    return self.dict:set(pools_key, serialised)
end


function _M.new(_, dict_name)
    local dict = shared[dict_name]
    if not dict then
        ngx.log(ngx.ERR, "Shared dictionary not found" )
        return nil
    end

    local configured = true
    if phase() == 'init' and dict:get(pools_key) == nil then
        dict:set(pools_key, serialise({}))
        configured = false
    end

    local self = {
        dict = dict
    }
    return setmetatable(self, mt), configured
end

-- A safe place in ngx.ctx for the current module instance (self).
function _M.ctx(self)
    local id = tostring(self)
    local ctx = ngx.ctx[id]
    if not ctx then
        ctx = {
            pools = {},
            failed = {}
        }
        ngx.ctx[id] = ctx
    end
    return ctx
end

-- Slow(ish) config / api functions

function _M.getPools(self)
    local pool_str = self.dict:get(pools_key)
    return loadstring(pool_str)()
end

function _M.setMethod(self, poolid, method)
    if not available_methods[method] then
        return nil, 'Method not found'
    end

    local pools = self:getPools()
    if not pools[poolid] then
        return nil, 'Pool not found'
    end
    pools[poolid].method = method

    return savePools(self, pools)
end

function _M.createPool(self, poolid)
    local pools = self:getPools()
    if pools[poolid] then
        return nil, 'Pool exists'
    end
    pools[poolid] = default_pool
    ngx.log(ngx.DEBUG, 'Added pool '..poolid)

    return savePools(self, pools)
end

function _M.setPriority(self, poolid, priority)
    assert(type(priority) == 'number', 'Priority must be a number')

    local pools = self:getPools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end

    pools[poolid].priority = priority

    local ok, err = savePools(self, pools)
    if not ok then
        return ok, err
    end
    return sortPools(self, pools)
end

function _M.addHost(self, poolid, host)
    local pools = self:getPools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end
    local pool = pools[poolid]

    -- Validate host definition and set defaults
    local hostid = #pool.hosts
    if host['id'] and pool.hosts[host['id']] == nil then
        hostid = host['id']
    end

    local new_host = {}
    for key, default in pairs(default_host) do
        if key == 'id' then
            default = count
        end
        local val = host[key] or default
        new_host[key] = val
    end

    pool.hosts[hostid] = new_host

    return savePools(self, pools)
end

function _M.removeHost(self, poolid, host)
end

function _M.setWeight(self, poolid, host, weight)
end


function _M.postProcess(self)
    local ctx = self.ctx()
    local pools = ctx.pools
    local failed = ctx.failed
    local now = now()

    -- Loop over all hosts in all pools
    for poolid,pool in pairs(pools) do
        local failed_hosts = failed[poolid] or {}

        for hostid, host in pairs(pool.hosts) do
            -- Reset any hosts past their timeout
             if host.lastfail ~= 0 and (host.lastfail + failed_timeout) < now then
                ngx_log(ngx_info, str_format('Host "%s" in Pool "%s" is up', host.id, poolid))
                host.up = true
                host.failcount = 0
                host.lastfail = 0
            end

            -- This host has failed this request
            if failed_hosts[host.id] then
                host.lastfail = now
                host.failcount = host.failcount + 1
                if host.failcount >= max_fails then
                    host.up = false
                    ngx_log(ngx_err, str_format('Host "%s" in Pool "%s" is down', host.id, poolid))
                end
            end
        end

    end

    savePools(self, pools)
end

-- Fast path
available_methods.round_robin = function(self, live_hosts, total_weight, sock, poolid, failed_hosts)
    local err

    update_time()
    randomseed(now())

    local num_hosts = #live_hosts
    -- Loop until we run out of hosts or have connected
    repeat
        -- New random each time round as the total_weight changes
        local rand = random(0,total_weight)
        local host = nil
        local running = 0

        -- Might need the index afterwards
        local idx = 0
        while idx <= num_hosts do
            idx = idx + 1
            local cur_host = live_hosts[idx]
            if cur_host ~= false then
                -- Keep a running total of the weights so far
                running = running + cur_host.weight
                if rand <= running then
                    host = cur_host
                    break
                end
            end
        end
        if not host then
            -- Run out of hosts, break out of the loop (go to next pool)
            break
        end

        local host_id, host_host, host_port = host.id, host.host, host.port

        -- Try connecting to the winner
        connected, err = sock:connect(host_host, host_port)

        if connected then
            return connected, sock, err, host
        else
            -- Set the tried host to false and drop the total_weight by that weight
            -- Flag the host as down
            failed_hosts[host_id] = true
            live_hosts[idx] = false
            total_weight = total_weight - host.weight
            ngx_log(ngx_err, str_format('Failed connecting to Host "%s (%s:%d)" from pool "%s"', host_id, host_host, host_port, poolid))
        end
    until connected
    return nil, sock, err, {}
end

function _M.connect(self)
    local dict = self.dict
    local dict_get = dict.get

    local serialised = dict_get(dict, priority_key)
    local priority_index =  loadstring(serialised)()
    local priority_count = #priority_index
    if priority_count == 0 then
        return nil, 'No pools found'
    end

    local serialised = dict_get(dict, pools_key)
    local pools = loadstring(serialised)()
    if not pools then
        return nil, 'Pools broken'
    end

    local ctx = self.ctx()
    ctx.pools = pools
    local failed = ctx.failed

    -- upvalue these to return errors later
    local connected, err = nil, nil
    local sock = ngx_socket_tcp()

    -- Loop over pools in priority order
    for i=1, priority_count do
        local poolid = priority_index[i]
        local pool = pools[poolid]

        -- Track failed hosts in ctx
        if not failed[poolid]  then
            failed[poolid] = {}
        end
        local failed_hosts = failed[poolid]

        if pool.up then
            local all_hosts = pool.hosts or {}
            local weights = {}
            local total_weight = 0
            local live_hosts = {}

            -- Get live hosts in the pool
            local num_hosts = 0
            for hostid, host in pairs(all_hosts) do
                -- Disregard dead hosts
                if host.up then
                    num_hosts = num_hosts+1
                    host.id = hostid
                    live_hosts[num_hosts] = host
                    total_weight = total_weight + host.weight
                end
            end

            -- Attempt a connection
            if num_hosts == 1 then
                -- Don't bother trying to balance between 1 host
                local host = live_hosts[1]

                connected, err = sock:connect(host.host, host.port)
                if not connected then
                    -- Flag host as failed
                    failed_hosts[host.id] = true
                    ngx_log(ngx_err, str_format('Failed connecting to Host "%s (%s:%d)" from pool "%s"', host.id, host.host, host.port, poolid))
                end
            elseif num_hosts > 0 then
                -- Set socket params
                sock:settimeout(pool.timeout)

                -- Load balance between available hosts using specified method
                connected, sock, err, host = available_methods[pool.method](self, live_hosts, total_weight, sock, poolid, failed_hosts)
            end

            if connected then
                ngx_log(ngx_debug, str_format('Connected to Host "%s (%s:%d)" from pool "%s"', host.id, host.host, host.port, poolid))
                return sock, err
            end
            -- Failed to connect, try next pool
            ngx_log(ngx_debug, str_format('Pool %s out of hosts', poolid))
        end
        -- Pool was dead, next
    end
    -- Didnt find any pools with working hosts, return the last error message
    return nil, err
end

return _M
