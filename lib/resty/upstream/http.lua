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
        upstream = upstream,
        httpc = http.new()
    }
    return setmetatable(self, mt)
end


local function failed_request(self, host, pool)

    local upstream = self.upstream
    local ctx = upstream:ctx()

    local ctx_pools = ctx.pools
    if not ctx_pools then
        return nil
    end

    local ctx_pool = ctx_pools[pool]
    if not ctx_pool then
        return nil
    end

    local ctx_host = ctx_pool.hosts[host]
    if not ctx_host then
        return nil
    end

    local failed_pool = ctx.failed[pool]
    if not failed_pool then
        ctx.failed[pool] = {}
        failed_pool = ctx.failed[pool]
    end
    failed_pool[host] = true
end


local function check_response(self, res, http_err, host, pool)
    if not res then
        -- Request failed in some fashion
        ngx_log(ngx_err, (http_err or "").. " from ".. (host.id or "unknown") )

        -- Mark host down and return
        failed_request(self, host.id, pool.id)

        return res, http_err
    else
        -- Got a response, check status
        local status_codes = pool.status_codes or default_status_codes
        local status_code = tostring(res.status)

        -- Status codes are always 3 characters, so check for #xx or ##x
        if status_codes[status_code]
            or status_codes[str_sub(status_code, 1, 1)..'xx']
            or status_codes[str_sub(status_code, 1, 2)..'x']
            then
            http_err = status_code
            res = nil
            failed_request(self, host.id, pool.id)
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
        return res, http_err
    end
end


function _M.request(self, params)
    local httpc = self.httpc
    local upstream = self.upstream
    local res_header = ngx.header
    local req = ngx.req

    local res, err, http_err, status_code, conn_info

    repeat
        httpc, conn_info = upstream:connect(httpc)

        if not httpc then
            -- Either failed to connect or http failed to all available hosts
            if http_err then
                ngx_log(ngx_err, 'Upstream Error: 502')
                return nil, {err = http_err, status =  502}
            end
            ngx_log(ngx_err, 'Upstream Error: 504')
            return nil, {err = conn_info, status = 504}
        end

        local host = conn_info.host or {}
        local pool = conn_info.pool or {}

        httpc:set_timeout(pool.read_timeout or defaults.read_timeout) -- read timeout
        res, http_err = httpc:request(params)

        res, http_err = check_response(self, res, http_err, host, pool)

    until res

    self.conn_info = conn_info
    return res, conn_info
end


function _M.set_keepalive(self)
    local pool = self.conn_info.pool
    local keepalive_timeout = pool.keepalive_timeout or defaults.keepalive_timeout
    local keepalive_pool    = pool.keepalive_pool    or defaults.keepalive_pool

    return self.httpc:set_keepalive(keepalive_timeout, keepalive_pool)
end


function _M.get_reused_times(self, ...)
    return self.httpc:get_reused_times(...)
end


function _M.close(self, ...)
    return self.httpc:close(...)
end

return _M