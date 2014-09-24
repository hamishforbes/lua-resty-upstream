local ngx_socket_tcp = ngx.socket.tcp
local ngx_timer_at = ngx.timer.at
local ngx_worker_pid = ngx.worker.pid
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local str_format = string.format
local tbl_insert = table.insert
local tbl_sort = table.sort
local now = ngx.now
local pairs = pairs
local ipairs = ipairs
local getfenv = getfenv
local shared = ngx.shared
local phase = ngx.get_phase
local cjson = require('cjson')
local json_encode = cjson.encode
local json_decode = cjson.decode
local resty_lock = require('resty.lock')

local _M = {
    _VERSION = '0.02',
    available_methods = {},
    background_period = 60
}

local mt = { __index = _M }


local background_thread
background_thread = function(premature, self)
    if premature then
        ngx_log(ngx_DEBUG, ngx_worker_pid(), " background thread prematurely exiting")
        return
    end
    -- Call ourselves on a timer again
    local ok, err = ngx_timer_at(self.background_period, background_thread, self)

    if not self:get_background_lock() then
        return
    end

    self:_background_func()

    self:release_background_lock()
end


function _M.get_background_lock(self)
    local pid = ngx_worker_pid()
    local dict = self.dict
    local lock, err = dict:add(self.background_flag, pid, self.background_period*3)
    if lock then
        return true
    end
    if err == 'exists' then
        return false
    else
        ngx_log(ngx_DEBUG, "Could not add key in ", pid)
        return false
    end
end


function _M.release_background_lock(self)
    local dict = self.dict
    local pid, err = dict:get(self.background_flag)
    if not pid then
        ngx_log(ngx_ERR, "Failed to get key '", self.background_flag, "': ", err)
        return
    end
    if pid == ngx_worker_pid() then
        local ok, err = dict:delete(self.background_flag)
        if not ok then
            ngx_log(ngx_ERR, "Failed to delete key '", self.background_flag, "': ", err)
        end
    end
end


function _M.new(_, dict_name, id)
    local dict = shared[dict_name]
    if not dict then
        ngx_log(ngx_ERR, "Shared dictionary not found" )
        return nil
    end

    if not id then id = 'default_upstream' end
    if type(id) ~= 'string' then
        return nil, 'Upstream ID must be a string'
    end

    local self = {
        id = id,
        dict = dict,
        dict_name = dict_name,
        rr_vars = {},
    }
    -- Create unique dictionary keys for this instance of upstream
    self.pools_key = self.id..'_pools'
    self.priority_key = self.id..'_priority_index'
    self.background_flag = self.id..'_background_running'
    self.lock_key = self.id..'_lock'

    local configured = true
    if dict:get(self.pools_key) == nil then
        dict:set(self.pools_key, json_encode({}))
        configured = false
    end

    return setmetatable(self, mt), configured
end


-- A safe place in ngx.ctx for the current module instance (self).
function _M.ctx(self)
    -- Straight up stolen from lua-resty-core
    -- No request available so must be the init phase, return an empty table
    if not getfenv(0).__ngx_req then
        return {}
    end
    local ngx_ctx = ngx.ctx
    local id = self.id
    local ctx = ngx_ctx[id]
    if ctx == nil then
        ctx = {
            failed = {}
        }
        ngx_ctx[id] = ctx
    end
    return ctx
end


function _M.get_pools(self)
    local ctx = self:ctx()
    if ctx.pools == nil then
        local pool_str = self.dict:get(self.pools_key)
        ctx.pools = json_decode(pool_str)
    end
    return ctx.pools
end


local function get_lock_obj(self)
    local ctx = self:ctx()
    if not ctx.lock then
        ctx.lock = resty_lock:new(self.dict_name)
    end
    return ctx.lock
end


function _M.get_locked_pools(self)
    if phase() == 'init' then
        return self:get_pools()
    end
    local lock = get_lock_obj(self)
    local ok, err = lock:lock(self.lock_key)

    if ok then
        local pool_str = self.dict:get(self.pools_key)
        local pools = json_decode(pool_str)
        return pools
    else
        ngx_log(ngx_ERR, str_format("Failed to lock pools for '%s': %s", self.id, err))
    end

    return ok, err
end


function _M.unlock_pools(self)
    if phase() == 'init' then
        return true
    end
    local lock = get_lock_obj(self)
    local ok, err = lock:unlock(self.lock_key)
    if not ok then
        ngx_log(ngx_ERR, str_format("Failed to release pools lock for '%s': %s", self.id, err))
    end
    return ok, err
end


function _M.get_priority_index(self)
    local ctx = self:ctx()
    if ctx.priority_index == nil then
        local priority_str = self.dict:get(self.priority_key)
        ctx.priority_index = json_decode(priority_str)
    end
    return ctx.priority_index
end


local function _gcd(a,b)
    -- Tail recursive gcd function
    if b == 0 then
        return a
    else
        return _gcd(b, a % b)
    end
end


local function calc_gcd_weight(hosts)
    -- Calculate the GCD and maximum weight value from a set of hosts
    local gcd = 0
    local len = #hosts - 1
    local max_weight = 0
    local i = 1

    if len < 1 then
        return 0, 0
    end

    repeat
        local tmp = _gcd(hosts[i].weight, hosts[i+1].weight)
        if tmp > gcd then
            gcd = tmp
        end
        if hosts[i].weight > max_weight then
            max_weight = hosts[i].weight
        end
        i = i +1
    until i >= len
    if hosts[i].weight > max_weight then
        max_weight = hosts[i+1].weight
    end

    return gcd, max_weight
end


function _M.save_pools(self, pools)
    -- Pool has changed, recalculate gcd and max_weight
    local rr_vars = self.rr_vars
    for id,pool in pairs(pools) do
        if not rr_vars[id] then
            rr_vars[id] = {idx = 0, cw = 0}
        end
        local pool_rr = rr_vars[id]
        pool_rr.gcd, pool_rr.max_weight = calc_gcd_weight(pool.hosts)
    end

    self:ctx().pools = pools
    local serialised = json_encode(pools)
    return self.dict:set(self.pools_key, serialised)
end


function _M.sort_pools(self, pools)
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

    local serialised = json_encode(sorted_pools)
    return self.dict:set(self.priority_key, serialised)
end


function _M.init_background_thread(self)
    local ok, err = ngx_timer_at(1, background_thread, self)
    if not ok then
        ngx_log(ngx_ERR, "Failed to start background thread: "..err)
    end
end


function _M._background_func(self)
    local now = now()

    -- Reset state for any failed hosts
    local pools = self:get_locked_pools()

    local changed = false
    for poolid,pool in pairs(pools) do
        local failed_timeout = pool.failed_timeout
        local max_fails = pool.max_fails
        for k, host in ipairs(pool.hosts) do
            -- Reset any hosts past their timeout
             if host.lastfail ~= 0 and (host.lastfail + failed_timeout) < now then
                ngx_log(ngx_INFO,
                    str_format('Host "%s" in Pool "%s" is up', host.id, poolid)
                )
                host.up = true
                host.failcount = 0
                host.lastfail = 0
                changed = true
            end
        end
    end

    local ok, err = true, nil
    if changed then
        ok, err = self:save_pools(pools)
        if not ok then
            ngx_log(ngx_ERR, "Error saving pools for upstream ", self.id, ": ", err)
        end
    end
    self:unlock_pools()
    return ok, err
end


function _M.get_host_idx(id, hosts)
    for i, host in ipairs(hosts) do
        if host.id == id then
            return i
        end
    end
    return nil
end


function _M._process_failed_hosts(premature, self, ctx)
    local failed = ctx.failed
    local now = now()
    local get_host_idx = self.get_host_idx

    local pools, err = self:get_locked_pools()
    if not pools then
        return
    end

    local changed = false
    for poolid,hosts in pairs(failed) do
        local pool = pools[poolid]
        local failed_timeout = pool.failed_timeout
        local max_fails = pool.max_fails
        local pool_hosts = pool.hosts

        for id,_ in pairs(hosts) do
            local host_idx = get_host_idx(id, pool_hosts)
            local host = pool_hosts[host_idx]

            changed = true
            host.lastfail = now
            host.failcount = host.failcount + 1
            if host.failcount >= max_fails and host.up == true then
                host.up = false
                ngx_log(ngx_ERR,
                    str_format('Host "%s" in Pool "%s" is down', host.id, poolid)
                )
            end
        end
    end

    local ok, err = true, nil
    if changed then
        ok, err = self:save_pools(pools)
        if not ok then
            ngx_log(ngx_ERR, "Error saving pools for upstream ", self.id, " ", err)
        end
    end

    self:unlock_pools()
    return ok, err
end


function _M.process_failed_hosts(self)
    -- Run in a background thread immediately after the request is done
    ngx_timer_at(0, self._process_failed_hosts, self, self:ctx())
end


function _M.get_failed_hosts(self, poolid)
    local f = self:ctx().failed
    local failed_hosts = f[poolid]
    if not failed_hosts then
        f[poolid] = {}
        failed_hosts = f[poolid]
    end
    return failed_hosts
end


function _M.connect_failed(self, host, poolid)
    -- Flag host as failed
    local hostid = host.id
    local failed_hosts = self:get_failed_hosts(poolid)
    failed_hosts[hostid] = true
    ngx_log(ngx_ERR,
        str_format('Failed connecting to Host "%s" (%s:%d) from pool "%s"',
            hostid,
            host.host,
            host.port,
            poolid
        )
    )
end


local function select_weighted_rr_host(hosts, failed_hosts, rr_vars)
    local idx = rr_vars.idx
    local cw = rr_vars.cw
    local gcd = rr_vars.gcd
    local max_weight = rr_vars.max_weight

    local hostcount = #hosts

    local iters = 0
    repeat
        idx = idx +1
        if idx > hostcount then
            idx = 1
        end
        if idx == 1 then
            cw = cw - gcd
            if cw <= 0 then
                cw = max_weight
                if cw == 0 then
                    return nil
                end
            end
        end
        local host = hosts[idx]
        if  host ~= false and
            host.up == true and
            host.weight >= cw and
            failed_hosts[host.id] == nil
            then
                rr_vars.idx, rr_vars.cw = idx, cw
                return host, idx
        end
        iters = iters+1
    until iters > hostcount -- Checked every host, must all be down
    return
end


_M.available_methods.round_robin = function(self, pool, sock)
    local hosts = pool.hosts
    local poolid = pool.id
    local rr_vars = self.rr_vars[pool.id]

    -- Attempt a connection
    if #hosts == 1 then
        -- Don't bother trying to balance between 1 host
        local host = hosts[1]
        local connected, err = sock:connect(host.host, host.port)
        if not connected then
            self:connect_failed(host, poolid)
        end
        return connected, sock, host, err
    end

    local failed_hosts = self:get_failed_hosts(poolid)

    -- Loop until we run out of hosts or have connected
    local connected, err
    repeat

        local host, idx = select_weighted_rr_host(hosts, failed_hosts, rr_vars)
        if not host then
            -- Ran out of hosts, break out of the loop (go to next pool)
            break
        end

        -- Try connecting to the selected host
        connected, err = sock:connect(host.host, host.port)

        if connected then
            return connected, sock, host, err
        else
            -- Mark the host bad and retry
            hosts[idx] = false
            self:connect_failed(host, poolid)
        end
    until connected
    -- All hosts have failed
    return nil, sock, {}, err
end


function _M.connect(self, sock)
    -- Get pool data
    local priority_index = self:get_priority_index()
    local pools = self:get_pools()
    if not pools or not priority_index then
        return nil, 'No valid pool data'
    end

    -- A socket (or resty client module) can be passed in, otherwise create a socket
    if not sock then
        sock = ngx_socket_tcp()
    end

    -- Resty modules use set_timeout instead
    local set_timeout = sock.settimeout or sock.set_timeout

    -- Upvalue these to return errors later
    local connected, err, host
    local available_methods = self.available_methods

    -- Loop over pools in priority order
    for _, poolid in ipairs(priority_index) do
        local pool = pools[poolid]

        if pool.up then
            pool.id = poolid
            -- Set connection timeout
            set_timeout(sock, pool.timeout)

            -- Load balance between available hosts using specified method
            connected, sock, host, err = available_methods[pool.method](self, pool, sock)

            if connected then
                -- Return connected socket!
                ngx_log(ngx_DEBUG, 'connected to '..host.id)
                return sock, {host = host, pool = pool}
            end
        end
    end
    -- Didnt find any pools with working hosts, return the last error message
    return nil, "No available upstream hosts"
end

return _M
