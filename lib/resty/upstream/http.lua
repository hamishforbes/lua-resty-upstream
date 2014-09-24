local ngx_worker_pid = ngx.worker.pid
local ngx_timer_at = ngx.timer.at
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG
local ngx_var = ngx.var
local str_lower = string.lower
local str_format = string.format
local str_sub = string.sub
local tostring = tostring
local http = require("resty.http")

local _M = {
    _VERSION = '0.02',
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

local check_defaults = {
    method = "GET",
    path = "/",
    headers = {
        ["User-Agent"] = "Resty Upstream/".. _M._VERSION.. " HTTP Check (lua)"
    }
}


local ssl_defaults = {
    ssl = false,
    ssl_verify = true,
    sni_host = nil,
}


function _M.new(_, upstream, ssl_opts)
    local ssl_opts = setmetatable(ssl_opts or {}, {__index = ssl_defaults})
    local self = {
        upstream = upstream,
        ssl_opts = ssl_opts
    }
    return setmetatable(self, mt)
end


local function failed_request(self, host, poolid)
    local upstream = self.upstream
    local failed_hosts = upstream:get_failed_hosts(poolid)
    failed_hosts[host] = true
end


local function http_check_request(self, httpc, params)
    -- Set params
    local req_params = {}
    if type(params) ~= 'table' then
        req_params = check_defaults
    else
        for k,v in pairs(check_defaults) do
            if not params[k] then
                req_params[k] = v
            else
                req_params[k] = params[k]
            end
        end
    end

    local res, err = httpc:request(req_params)

    -- Read and discard body
    local reader
    if res then
        reader = res.body_reader
    end
    if reader then
        repeat
            local chunk, err = reader(65536)
            if err then
              ngx_log(ngx_ERR, "Read Error: "..(err or ""))
              break
            end
        until not chunk
    end

    -- Don't use keepalives in background checks
    httpc:close()

    return res, err
end


function _M._http_background_func(self)
    -- Active HTTP checks
    local upstream = self.upstream
    local httpc = http.new()
    local pools = upstream:get_pools()

    for poolid, pool in pairs(pools) do
        pool.id = poolid
        for _, host in ipairs(pool.hosts) do
            if host.healthcheck ~= nil and host.healthcheck ~= false then
                -- Set connect timeout
                httpc:set_timeout(pool.timeout)

                local ok,err = httpc:connect(host.host, host.port)
                if not ok then
                    failed_request(self, host.id, pool.id)
                    if host.up then
                        -- Only log if it wasn't already down
                        ngx_log(ngx_ERR,
                            str_format("Connection failed for host %s (%s:%i) in pool %s: %s",
                             host.id, host.host, host.port, poolid, err)
                        )
                    end
                else
                    -- Set read timeout
                    httpc:set_timeout(pool.read_timeout or defaults.read_timeout)

                    local ssl_opts = self.ssl_opts
                    if ssl_opts.ssl then
                        -- TODO: SSL Session reuse
                        local ok, err = httpc:ssl_handshake(nil, ssl_opts.sni_name, ssl_opts.verify)
                        if not ok then
                            failed_request(self, host.id, pool.id)
                            if host.up then
                                -- Only log if it wasn't already down
                                ngx_log(ngx_ERR,
                                    str_format("SSL Handshake failed for host %s (%s:%i) in pool %s: %s",
                                     host.id, host.host, host.port, poolid, err)
                                )
                            end
                        end
                    end

                    local res, err = http_check_request(self, httpc, host.healthcheck)
                    res, err = self:check_response(res, err, host, pool)
                end
            end
        end
    end
end


local http_background_thread
http_background_thread = function(premature, self)
    if premature then
        ngx_log(ngx_DEBUG, ngx_worker_pid(), " background thread prematurely exiting")
        return
    end
    local upstream = self.upstream

    -- Call ourselves on a timer again
    local ok, err = ngx_timer_at(upstream.background_period, http_background_thread, self)

    if not upstream:get_background_lock() then
        return
    end

    -- HTTP active checks
    self:_http_background_func()
    -- Run process_failed_hosts inline rather than after the request is done
    upstream._process_failed_hosts(false, upstream, upstream:ctx())

    -- Run upstream.socket background thread
    upstream:_background_func()

    upstream:release_background_lock()
end


function _M.init_background_thread(self)
    local ok, err = ngx_timer_at(1, http_background_thread, self)
    if not ok then
        ngx_log(ngx_ERR, "Failed to start background thread: "..err)
    end
end


function _M.check_response(self, res, http_err, host, pool)
    if not res then
        -- Request failed in some fashion
        if host.up == true then
            ngx_log(ngx_ERR, "HTTP Request Error from host '",
                    (host.id or "unknown"),
                    "' in pool '",
                    pool.id,
                    "': ",
                    (http_err or "")
                )
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
                ngx_log(ngx_ERR,
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
    local ctx = self.upstream:ctx()
    if not ctx.httpc then
        ctx.httpc = http.new()
    end
    return ctx.httpc
end


function _M.get_client_body_reader(self, ...)
    return self:httpc():get_client_body_reader(...)
end


local function _request(self, upstream, httpc, params)
    local httpc, conn_info = upstream:connect(httpc)

    if not httpc then
        -- Connection err
        return nil, conn_info
    end

    local host = conn_info.host or {}
    local pool = conn_info.pool or {}

    local ssl_opts = self.ssl_opts
    if ssl_opts.ssl then
        -- TODO: SSL Session reuse
        local ok, err = httpc:ssl_handshake(nil, ssl_opts.sni_host or ngx.var.host, ssl_opts.ssl_verify)
        if not ok then
            ngx_log(ngx_ERR, "SSL Error: ",err)
            failed_request(self, host.id, pool.id)
            return ok, err
        end
    end

    httpc:set_timeout(pool.read_timeout or defaults.read_timeout)

    local res, http_err = httpc:request(params)
    res, http_err = self:check_response(res, http_err, host, pool)

    if not res then
        return nil, http_err
    end
    return res, conn_info
end


function _M.request(self, params)
    local httpc = self:httpc()
    local upstream = self.upstream

    local prev_err
    repeat
        local res, err = _request(self, upstream, httpc, params)
        if res then
            self.conn_info = err
            return res, err
        else
            -- Either connect or http failed to all available hosts
            if err == "No available upstream hosts" then
                if prev_err then
                    -- Got a connection at some point but bad HTTP
                    return nil, {err = prev_err, status = 502}
                else
                    -- No connections at all
                    return nil, {err = err, status = 504}
                end
            end
            prev_err = err
        end
    until res
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