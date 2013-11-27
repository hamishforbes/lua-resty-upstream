local ngx_log = ngx.log
local ngx_err = ngx.ERR
local flush = ngx.flush
local print = ngx.print
local req = ngx.req
local ngx_var = ngx.var
local str_lower = string.lower
local res_header = ngx.header

local http_upstream = Upstream_HTTP:new(upstream)

local res, conn_info = http_upstream:request{
    method = req.get_method(),
    path = (ngx_var.uri .. ngx_var.is_args .. (ngx_var.args or "")),
    body = req.get_body_data(), -- TODO: stream this into httpc?
    headers = req.get_headers(),
}

if not res then
    ngx.status = conn_info.status
    ngx.say(conn_info.err)
    return ngx.exit(ngx.status)
end

ngx.status = res.status

local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
}

for k,v in pairs(res.headers) do
    if not HOP_BY_HOP_HEADERS[str_lower(k)] then
        res_header[k] = v
    end
end

local reader = res.body_reader
repeat
    local chunk, err = reader()
    if err then
      ngx_log(ngx_ERR, "Read Error: "..(err or ""))
      break
    end

    if chunk then
      print(chunk)
      flush(true)
    end
until not chunk

local ok,err = http_upstream:set_keepalive()

