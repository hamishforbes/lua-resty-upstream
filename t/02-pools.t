# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (7);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;

    init_by_lua '
        socket_upstream = require("resty.upstream.socket")

        local dict = ngx.shared["test_upstream"]
        dict:delete("pools")

        upstream, configured = socket_upstream:new("test_upstream")

        upstream:createPool({id = "primary", timeout = 100})

        upstream:createPool({id = "secondary", timeout = 100, priority = 10})
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Cannot add existing pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local ok,err = upstream:createPool({id = "primary"})
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- errorcode: 200

=== TEST 2: Failover to secondary pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
        -- Bad hosts
            upstream:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
            upstream:addHost("primary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
        -- Good hosts
            upstream:addHost("secondary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 10 })
            upstream:addHost("secondary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 10 })

            local sock, err = upstream:connect()
            if not sock then
                ngx.say(err)
            else
                sock:close()
                ngx.say("OK")
            end
        ';
    }
--- request
GET /a
--- response_body
OK
--- error_log: from pool "secondary"

=== TEST 3: Cannot set unavailable load-balancing method
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = upstream:setMethod("primary", "foobar")
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 4: Cannot set non-numeric priority
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = upstream:setPriority("primary", "foobar")
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 5: Cannot create pool with bad values
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = upstream:createPool({
                    id = "testpool",
                    priority = "abcd",
                    timeout = "foo",
                    method = "bar",
                    max_fails = "three",
                    fail_timeout = "sixty"
                })

            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

