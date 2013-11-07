local ngx_socket_tcp = ngx.socket.tcp
local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_info = ngx.INFO
local str_format = string.format
local tbl_insert = table.insert
local tbl_sort = table.sort
local tbl_len = table.getn
local randomseed = math.randomseed
local random = math.random
local now = ngx.now
local update_time = ngx.update_time
local shared = ngx.shared
local phase = ngx.get_phase
local loadstring = loadstring
local serpent = require('resty.upstream.serpent')
local serialise = serpent.dump


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }

local default_pool = {
    up = true,
    method = 'round_robin',
    timeout = 2000, -- socket timeout
    priority = 0,
    -- Hosts in this pool must fail `max_fails` times in `failed_timeout` seconds to be marked down for `failed_timeout` seconds
    failed_timeout = 60,
    max_fails = 3,
    hosts = {}
}
local numerics = {'priority', 'timeout', 'failed_timeout', 'max_fails'}

local default_host = {
    host = '',
    port = 80,
    up = true,
    weight = 0,
    failcount = 0,
    lastfail = 0
}

local available_methods = { }

local pools_key = 'pools'
local priority_key = 'priority_index'
local background_flag = 'background_running'
local background_period = 60

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

local background_thread
background_thread = function(premature, self)
    if premature then
        -- worker is reloading, remove the flag
        self.dict:delete(background_flag)
        return
    end

    self:_backgroundFunc()

    -- Call ourselves on a timer again
    local ok, err = ngx.timer.at(background_period, background_thread, self)
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

local function validatePool(opts, pools)
    if pools[opts.id] then
        return nil, 'Pool exists'
    end

    for _,key in ipairs(numerics) do
        if opts[key] and type(opts[key]) ~= "number" then
            return nil, key.. " must be a number"
        end
    end
    if opts[method] and not available_methods[opts[method]] then
        return nil, 'Method not available'
    end
    return true
end

function _M.createPool(self, opts)
    local poolid = opts.id
    if not poolid then
        return nil, 'No ID set'
    end

    local pools = self:getPools()

    local ok, err = validatePool(opts, pools)
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
    pools[poolid] = pool

    local ok, err = savePools(self, pools)
    if not ok then
        return ok, err
    end
    ngx.log(ngx.DEBUG, 'Created pool '..poolid)
    return sortPools(self, pools)
end

function _M.setPriority(self, poolid, priority)
    if type(priority) ~= 'number' then
        return nil, 'Priority must be a number'
    end

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

function _M.setWeight(self, poolid, weight)

end

function _M.addHost(self, poolid, host)
    local pools = self:getPools()
    if pools[poolid] == nil then
        return nil, 'Pool not found'
    end
    local pool = pools[poolid]

    -- Validate host definition and set defaults
    local hostid = host['id']
    if not hostid or pool.hosts[hostid] ~= nil then
        hostid = tbl_len(pool.hosts)+1
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
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end

    pool.hosts[host] = nil

    return savePools(self, pools)
end

function _M.hostDown(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool '.. poolid ..' not found'
    end
    local host = pool.hosts[host]
    if not host then
        return nil, 'Host not found'
    end

    host.up = false
    host.manual = true
    ngx_log(ngx_debug, str_format('Host "%s" in Pool "%s" is manually down', host.id, poolid))

    return savePools(self, pools)
end

function _M.hostUp(self, poolid, host)
    if not poolid or not host then
        return nil, 'Pool or host not specified'
    end
    local pools = self:getPools()
    if not pools then
        return nil, 'No Pools'
    end
    local pool = pools[poolid]
    if not pool then
        return nil, 'Pool not found'
    end
    local host = pool.hosts[host]
    if not host then
        return nil, 'Host not found'
    end

    host.up = true
    host.manual = nil
    ngx_log(ngx_debug, str_format('Host "%s" in Pool "%s" is manually up', host.id, poolid))

    return savePools(self, pools)
end

function _M.postProcess(self)
    local ctx = self.ctx()
    local pools = ctx.pools
    local failed = ctx.failed
    local now = now()


    for poolid,hosts in pairs(failed) do
        for hostid,_ in pairs(hosts) do
            local pool = pools[poolid]
            local failed_timeout = pool.failed_timeout
            local max_fails = pool.max_fails
            local host = pool.hosts[hostid]

            host.lastfail = now
            host.failcount = host.failcount + 1
            if host.failcount >= max_fails then
                host.up = false
                ngx_log(ngx_err, str_format('Host "%s" in Pool "%s" is down', host.id, poolid))
            end
        end
    end

    return savePools(self, pools)
end

function _M._backgroundFunc(self)
    local now = now()

    -- Reset state for any failed hosts
    local pools = self:getPools()
    for poolid,pool in pairs(pools) do
        local failed_timeout = pool.failed_timeout
        local max_fails = pool.max_fails
        for hostid, host in pairs(pool.hosts) do
            -- Reset any hosts past their timeout
             if host.lastfail ~= 0 and (host.lastfail + failed_timeout) < now then
                ngx_log(ngx_info, str_format('Host "%s" in Pool "%s" is up', host.id, poolid))
                host.up = true
                host.failcount = 0
                host.lastfail = 0
            end
        end
    end

    return savePools(self, pools)
end

-- Fast path
local function getLiveHosts(all_hosts)
    if all_hosts == nil then
        return {}, 0, 0
    end

    local live_hosts = {}
    local total_weight = 0

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

    return live_hosts, num_hosts, total_weight
end

local function connectFailed(failed_hosts, id, host, port, poolid)
    -- Flag host as failed
    failed_hosts[id] = true
    ngx_log(ngx_err, str_format('Failed connecting to Host "%s" (%s:%d) from pool "%s"', id, host, port, poolid))
end

available_methods.round_robin = function(self, live_hosts, total_weight, sock, poolid)
    local err

    local failed = self.ctx().failed
    if not failed[poolid]  then
        failed[poolid] = {}
    end
    local failed_hosts = failed[poolid]

    update_time()
    randomseed(now())

    local num_hosts = #live_hosts
    -- Loop until we run out of hosts or have connected
    repeat
        local rand = random(0,total_weight)
        local host = nil
        local running = 0

        -- Might need the index afterwards
        local idx = 0
        while idx < num_hosts do
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

        -- Try connecting to the winner
        local host_id, host_host, host_port, host_weight = host.id, host.host, host.port, host.weight
        connected, err = sock:connect(host_host, host_port)

        if connected then
            return connected, sock, err, host
        else
            -- Set the tried host to false and drop the total_weight by that weight
            live_hosts[idx] = false
            total_weight = total_weight - host_weight

            connectFailed(failed_hosts, host_id, host_host, host_port, poolid)
        end
    until connected
    return nil, sock, err, {}
end

function _M.connect(self, sock)
    local dict = self.dict
    local dict_get = dict.get

    -- Launch the background process if not running
    local background_running = dict_get(dict, background_flag)
    if not background_running then
        local ok, err = ngx.timer.at(background_period, background_thread, self)
        if ok then
            dict:set(background_flag, 1)
        end
    end

    -- Get pool data
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

    -- Add pools to ctx for post-processing
    local ctx = self.ctx()
    ctx.pools = pools

    -- upvalue these to return errors later
    local connected, err = nil, nil

    -- A socket (or resty client module...) can be passed in, otherwise create a socket
    if not sock then
        sock = ngx_socket_tcp()
    end
     -- resty modules use set_timeout instead
    local set_timeout = sock.settimeout or sock.set_timeout

    -- Loop over pools in priority order
    for i=1, priority_count do
        local poolid = priority_index[i]
        local pool = pools[poolid]

        if pool.up then
            local live_hosts, num_hosts, total_weight = getLiveHosts(pool.hosts)

            set_timeout(sock, pool.timeout)

            -- Attempt a connection
            local host
            if num_hosts == 1 then
                -- Don't bother trying to balance between 1 host
                host = live_hosts[1]
                connected, err = sock:connect(host.host, host.port)
                if not connected then
                    local failed = self.ctx().failed
                    if not failed[poolid]  then
                        failed[poolid] = {}
                    end
                    connectFailed(failed[poolid], host.id, host.host, host.port, poolid)
                end
            elseif num_hosts > 0 then
                -- Load balance between available hosts using specified method
                connected, sock, err, host = available_methods[pool.method](self, live_hosts, total_weight, sock, poolid)
            end

            if connected then
                ngx_log(ngx_debug, str_format('Connected to Host "%s" (%s:%d) from pool "%s"', host.id, host.host, host.port, poolid))
                return sock, {host = host, pool = pool}
            end
            -- Failed to connect, try next pool
        end
        -- Pool was dead, next
    end
    -- Didnt find any pools with working hosts, return the last error message
    return nil, err
end

return _M
