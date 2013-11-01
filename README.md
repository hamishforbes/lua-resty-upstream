lua_shared_dict my_upstream 1m;

init_by_lua '
    socket_upstream  = require("resty.socket-upstream")

    upstream, configured = socket_upstream:new("my_upstream")
    if not configured then -- Only reconfigure on start, shared mem persists across a HUP

        upstream:createPool("primary")
        upstream:setPriority("primary", 0)
        upstream:setMethod("primary", "round_robin")
        upstream:addHost("primary", { id="a", host = "127.0.0.1", port = "80", keepalive = 256, weight = 10 })
        upstream:addHost("primary", { id="b", host = "127.0.0.1", port = "81", keepalive = 256, weight = 10 })

        upstream:createPool("dr")
        upstream:setPriority("dr", 10)
        upstream:addHost("dr", { host = "127.0.0.1", port = "82", keepalive = nil, weight = 5 })
        upstream:addHost("dr", { host = "127.0.0.1", port = "83", keepalive = nil, weight = 10 })

        upstream:createPool("test")
        upstream:setPriority("test", 5)
        upstream:addHost("primary", { id="c", host = "127.0.0.1", port = "82", keepalive = 256, weight = 10 })
        upstream:addHost("primary", { id="d", host = "127.0.0.1", port = "83", keepalive = 256, weight = 10 })
    end

';

content_by_lua '
    local sock, err = upstream:connect()
';

log_by_lua '
    upstream:postProcess()
';