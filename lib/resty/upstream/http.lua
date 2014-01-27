local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG
local ngx_var = ngx.var
local str_lower = string.lower
local str_format = string.format
local str_sub = string.sub
local tostring = tostring
local http = require("resty.http")

local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }

local default_status_codes = {
    ['5xx'] = true,
    ['400'] = true
}

local defaults = {
    read_timeout = 10000,
    keepalive_timeout = 60000,
    keepalive_pool = 128
}


function _M.new(_, upstream)
    local self = {
        upstream = upstream
    }
    return setmetatable(self, mt)
end


local function failed_request(self, host, pool)
    local upstream = self.upstream
    local ctx = upstream:ctx()

    local failed_pool = ctx.failed[pool]
    if not failed_pool then
        ctx.failed[pool] = {}
        failed_pool = ctx.failed[pool]
    end
    failed_pool[host] = true
end


local http_background_func = function(self)
    -- Active HTTP checks
    local upstream = self.upstream
    local httpc = http.new()
    local pools = upstream:get_pools()

    for poolid, pool in pairs(pools) do
        pool.id = poolid
        for _, host in ipairs(pool.hosts) do

            local ok,err = httpc:connect(host.host, host.port)
            if not ok then

                failed_request(self, host.id, pool.id)

                if host.up then
                    -- Only log if it wasn't already down
                    ngx_log(ngx_err,
                        str_format("Connection failed for host %s (%s:%i) in pool %s",
                         host.id, host.host, host.port, poolid)
                    )
                end
            else
                local res, err = httpc:request({
                        headers = {
                            ["User-Agent"] = "Resty Upstream/".. self._VERSION.. " HTTP Check"
                        }
                    })

                res, err = self:check_response(res, err, host, pool)
            end
        end
    end

end


local http_background_thread
http_background_thread = function(premature, self)
    local upstream = self.upstream
    if premature then
        -- worker is reloading, remove the flag
        upstream.dict:delete(upstream.background_flag)
        return
    end

    -- HTTP active checks
    --upstream:post_process()     -- Restore any hosts out of their dead period
    http_background_func(self)  -- Check live and restored hosts
    upstream:post_process()     -- Down any failed hosts

    -- Run upstream.socket background thread
    upstream:_background_func()

    -- Call ourselves on a timer again
    local ok, err = ngx.timer.at(upstream.background_period, http_background_thread, self)
end


-- Wrapper on upstream.socket's _init_background_thread
function _M.init_background_thread(self)
    local upstream = self.upstream
    upstream._init_background_thread(upstream.dict, upstream.background_flag, http_background_thread, self)
end


function _M.check_response(self, res, http_err, host, pool)
    if not res then
        -- Request failed in some fashion
        if host.up == true then
            ngx_log(ngx_err, (http_err or "").. " from ".. (host.id or "unknown") )
        end

        -- Mark host down and return
        failed_request(self, host.id, pool.id)

    else
        -- Got a response, check status
        local status_codes = pool.status_codes or default_status_codes
        local status_code = tostring(res.status)

        -- Status codes are always 3 characters, so check for #xx or ##x
        if status_codes[status_code]
            or status_codes[str_sub(status_code, 1, 1)..'xx']
            or status_codes[str_sub(status_code, 1, 2)..'x']
            then

            res = nil -- Set res to nil so the outer loop re-runs
            http_err = status_code
            failed_request(self, host.id, pool.id)

            if host.up == true then
                ngx_log(ngx_err,
                    str_format('HTTP %s from Host "%s" (%s:%i) in pool "%s"',
                        status_code or "nil",
                        host.id     or "nil",
                        host.host   or "nil",
                        host.port   or "nil",
                        pool.id     or "nil"
                    )
                )
            end
        end
    end
    return res, http_err
end


function _M.httpc(self)
    local upstream = self.upstream
    local ctx = upstream:ctx()
    if not ctx.httpc then
        ctx.httpc = http.new()
    end
    return ctx.httpc
end

function _M.request(self, params)
    local httpc = self:httpc()
    local upstream = self.upstream
    local res_header = ngx.header
    local req = ngx.req

    local res, err, http_err, status_code, conn_info

    repeat
        httpc, conn_info = upstream:connect(httpc)

        if not httpc then
            -- Either connect or http failed to all available hosts
            if http_err then
                ngx_log(ngx_err, 'Upstream Error: 502')
                return nil, {err = http_err, status =  502}
            end
            ngx_log(ngx_err, 'Upstream Error: 504')
            return nil, {err = conn_info, status = 504}
        end

        local host = conn_info.host or {}
        local pool = conn_info.pool or {}

        httpc:set_timeout(pool.read_timeout or defaults.read_timeout)

        res, http_err = httpc:request(params)
        res, http_err = self:check_response(res, http_err, host, pool)
    until res

    self.conn_info = conn_info
    return res, conn_info
end


function _M.set_keepalive(self)

    local pool = self.conn_info.pool
    local keepalive_timeout = pool.keepalive_timeout or defaults.keepalive_timeout
    local keepalive_pool    = pool.keepalive_pool    or defaults.keepalive_pool

    return self:httpc():set_keepalive(keepalive_timeout, keepalive_pool)
end


function _M.get_reused_times(self, ...)
    return self:httpc():get_reused_times(...)
end


function _M.close(self, ...)
    return self:httpc():close(...)
end

return _M